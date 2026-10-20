# Opt-in: never put a VM boot on the inexpensive interactive preflight path.
{ pkgs, updateWorker }:
let
  setup = pkgs.writeText "update-workflow-fixture.py" ''
    import json, os, pathlib, pwd, shutil, subprocess
    root = pathlib.Path("/tmp/update-fixture")
    root.mkdir()
    user = pwd.getpwnam("source")
    for name in ("flake", "user", "state", "ai"):
        (root / name).mkdir()
    for name in ("flake", "user"):
        os.chown(root / name, user.pw_uid, user.pw_gid)
    for name, role in (("worker", "worker"), ("helper", "local-build")):
        shutil.copyfile("${updateWorker.testDriver}", root / name)
        (root / name).chmod(0o755)
        (root / (name + ".effect.json")).write_text(json.dumps({"root":str(root),"role":role}))
    config = json.loads(pathlib.Path("${updateWorker.testConfig}").read_text())
    config.update(flake_directory=str(root / "flake"), state_directory=str(root / "state"),
                  ai_state_directory=str(root / "ai"), username="source", host_name="vm-test",
                  local_build_helper=str(root / "helper"), deployment_lock=str(root / "deployment.lock"))
    (root / "config.json").write_text(json.dumps(config))
    for index in range(100):
        (root / "flake" / ("source-" + str(index))).write_text("committed content\n")
    (root / "flake/flake.lock").write_text(json.dumps({"version":7,"root":"root","nodes":{"root":{"inputs":{}}}}))
    for file in (root / "flake").iterdir():
        os.chown(file, user.pw_uid, user.pw_gid)
    def git(*args):
        subprocess.run(["runuser", "-u", "source", "--", "git", "-C", str(root / "flake"),
                        "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args], check=True)
    git("init", "-q")
    git("add", ".")
    git("commit", "-qm", "baseline")
  '';
in
pkgs.testers.runNixOSTest {
  name = "update-workflow";
  nodes.machine = {
    users.users.source.isNormalUser = true;
    environment.systemPackages = [
      pkgs.git
      pkgs.python3
      pkgs.nixos-rebuild
    ];
    system = {
      stateVersion = "26.05";
      switch.enable = true;
      extraDependencies = [ setup ];
    };
    virtualisation = {
      memorySize = 2048;
      diskSize = 4096;
      useBootLoader = true;
    };
  };
  testScript = ''
    import json
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("python3 ${setup}")
    root = "/tmp/update-fixture"
    machine.succeed(f"runuser -u source -- {root}/worker source prepare {root}/flake {root}/user/sources {root}/user/manifest.json")
    def sessions():
        machine.succeed("journalctl --sync")
        return int(machine.succeed("journalctl -o cat --no-pager | grep -c 'pam_unix(runuser:session): session opened' || true").strip())
    before = sessions()
    machine.succeed(f"{root}/worker approve-current {root}/user/manifest.json")
    count = sessions() - before
    assert 0 < count <= 5, f"100 files opened {count} PAM sessions"
    approval = machine.succeed(f"cat {root}/state/approval.json")
    assert json.loads(approval)["approved_at"] > 0
    machine.succeed(f"echo changed > {root}/flake/source-0")
    machine.fail(f"{root}/worker approve-current {root}/user/manifest.json")
    assert machine.succeed(f"cat {root}/state/approval.json") == approval
    # Exercise real profile/boot/activation semantics, only inside this VM.
    system = machine.succeed("readlink -f /run/current-system").strip()
    machine.succeed(f"nixos-rebuild switch --store-path {system} --no-reexec")
    assert machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == system
    machine.wait_for_unit("multi-user.target")
  '';
}
