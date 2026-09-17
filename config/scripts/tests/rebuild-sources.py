"""Exercise the real rebuild control flow with fake Nix/systemd/sudo commands."""
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    flake = root / "flake"
    flake.mkdir()
    (flake / "flake.nix").write_text("before\n")
    (flake / "flake.lock").write_text("{}\n")
    subprocess.run(["git", "init", "-q", str(flake)], check=True)
    subprocess.run(["git", "-C", str(flake), "add", "."], check=True)
    subprocess.run(["git", "-C", str(flake), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "commit", "-qm", "initial"], check=True)
    binaries = root / "bin"
    binaries.mkdir()
    events = root / "events"

    def executable(name, text):
        path = binaries / name
        path.write_text(f"#!{shutil.which('bash')}\nset -eu\n" + text)
        path.chmod(0o755)
        return path

    sudo = executable("sudo", 'printf "%s\\n" "$*" >> "$SUDO_EVENTS"\nif [ "$1" = -v ]; then exit 0; fi\nexec "$@"\n')
    executable("systemctl", '''
printf '%s\\n' "$*" >> "$STACK_EVENTS"
case "$*" in
  *is-active*graphical-session.target) exit "${GRAPHICAL_STATUS:-1}" ;;
  *is-active*bar-battery-helper.service) exit 1 ;;
  *restart*app-daemon.service*) exit "${DAEMON_RESTART_STATUS:-0}" ;;
  *is-active*)
    # Match systemctl's real any-active semantics for a multi-unit query.
    if [ "$#" -eq 4 ] && [ "${4}" = "${INACTIVE_UNIT:-}" ]; then exit 3; fi
    exit 0 ;;
esac
''')
    executable("nix", '''
if [ "$1" = path-info ]; then exit 1; fi
[ "$1 $2" = 'flake check' ]
[ "$4" = --no-update-lock-file ]
source=${3#path:}
[ "$(< "$source/flake.nix")" = before ]
printf 'check %s\n' "$3" >> "$EVENTS"
''')
    executable("nixos-rebuild", '''
[ "$1" = switch ]
[ "$2" = --flake ]
[ "$4" = --no-update-lock-file ]
source=${3#path:}
source=${source%#thinkpad}
[ "$(< "$source/flake.nix")" = before ]
printf 'switch %s\n' "$3" >> "$EVENTS"
exit "${SWITCH_STATUS:-0}"
''')
    helper = root / "local-build.py"
    helper.write_text('''import shutil

def read_inputs(root):
    return {}

def merge(left, right):
    return dict(left, **right)

def snapshot(source, target):
    target.mkdir(parents=True)
    for name in ("flake.nix", "flake.lock"):
        shutil.copyfile(source / name, target / name)

def prepare(source, destination):
    staged = destination / "root"
    snapshot(source, staged)
    # Simulate an edit after capture: neither check nor switch may consume it.
    (source / "flake.nix").write_text("later edit\\n")
    return {"flake": "path:" + str(staged)}
''')
    approval = executable("approval", f'python3 {scripts / "rebuild-source-state.py"} verify {flake} "$2"\n')
    rendered = (scripts / "rebuild.sh").read_text()
    for old, new in {
        "@CONFIG_DIRECTORY@": str(flake),
        "@FLAKE_ATTR@": "thinkpad",
        "@LOCAL_BUILD_HELPER@": str(helper),
        "@SOURCE_STATE_HELPER@": str(scripts / "rebuild-source-state.py"),
        "@APPROVAL_HELPER@": str(approval),
        "@DEPLOYMENT_LOCK_HELPER@": str(scripts / "deployment-lock.sh"),
        "/run/wrappers/bin/sudo": str(sudo),
    }.items():
        rendered = rendered.replace(old, new)
    script = root / "rebuild.sh"
    script.write_text(rendered)
    lock = root / "deployment.lock"
    lock.touch()
    environment = dict(os.environ, PATH=str(binaries) + ":" + os.environ["PATH"],
                       HOME=str(root), XDG_STATE_HOME=str(root / "state"),
                       NIXOS_DEPLOYMENT_LOCK_FILE=str(lock), EVENTS=str(events),
                       STACK_EVENTS=str(root / "stack-events"), SUDO_EVENTS=str(root / "sudo-events"))
    environment.pop("NIXOS_LOCAL_BUILD_HELPER", None)
    environment.pop("NIXOS_DEPLOYMENT_LOCK_HELPER", None)
    result = subprocess.run(["bash", str(script)], env=environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    checked, switched = events.read_text().splitlines()
    assert switched == "switch " + checked.removeprefix("check ") + "#thinkpad"
    assert (flake / "flake.nix").read_text() == "later edit\n"
    assert (flake / "flake.lock").read_text() == "{}\n"
    assert "baseline not approved: sources changed during build" in result.stdout
    assert not Path(checked.removeprefix("check path:")).exists(), "snapshot leaked after exit"
    forbidden = [
        ["--override-input", "daemon-framework", "old"], ["--flake", "other"],
        ["--flake=other"], ["-F", "other"], ["-Fother"], ["-F=other"],
        ["--no-flake"], ["--rollback"], ["--target-host", "other"],
        ["--target-host=other"], ["--build-host", "other"], ["--profile-name", "other"],
        ["--specialisation", "other"], ["--file", "other"], ["--store-path", "other"],
        ["--option", "eval-store", "other"], ["--impure"], ["--"], ["boot"],
        ["--cores"], ["--cores="], ["--cores", "-Fother"], ["--cores=auto"],
        ["--max-jobs", "other"], ["-j-Fother"], ["--verbose=true"],
    ]
    for arguments in forbidden:
        result = subprocess.run(["bash", str(script), *arguments],
                                env=environment, text=True, capture_output=True)
        assert result.returncode == 2, (arguments, result.stdout, result.stderr)
        assert len(events.read_text().splitlines()) == 2, "override reached build commands"

    for arguments in (["-L", "--show-trace", "--cores=2", "-j4"],
                      ["--max-jobs", "auto", "--cores", "0", "--offline"]):
        (flake / "flake.nix").write_text("before\n")
        result = subprocess.run(["bash", str(script), *arguments],
                                env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
    (flake / "untracked.txt").write_text("do not stage or delete\n")
    before_sudo = (root / "sudo-events").read_text()
    result = subprocess.run(["bash", str(script)], env=environment, text=True, capture_output=True)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Untracked files in" in result.stdout and "untracked.txt" in result.stdout
    assert (root / "sudo-events").read_text() == before_sudo, "preflight prompted for sudo"
    assert (flake / "untracked.txt").read_text() == "do not stage or delete\n"
    (flake / "untracked.txt").unlink()

    for overrides, expected in [
        ({"GRAPHICAL_STATUS": "0"}, 0),
        ({"GRAPHICAL_STATUS": "0", "INACTIVE_UNIT": "bt-daemon.service"}, 3),
        ({"GRAPHICAL_STATUS": "0", "DAEMON_RESTART_STATUS": "7"}, 7),
        ({"GRAPHICAL_STATUS": "0", "SWITCH_STATUS": "42", "INACTIVE_UNIT": "bt-daemon.service"}, 42),
    ]:
        (flake / "flake.nix").write_text("before\n")
        (root / "stack-events").write_text("")
        result = subprocess.run(["bash", str(script)], env=dict(environment, **overrides),
                                text=True, capture_output=True)
        assert result.returncode == expected, result.stdout + result.stderr
        stack = (root / "stack-events").read_text()
        assert "--user restart shelllist.service\n" in stack, "frontend recovery was skipped"
        for unit in ("app-daemon", "bar-daemon", "bt-daemon", "clip-daemon", "nm-daemon", "shelllist"):
            assert f"--user --quiet is-active {unit}.service\n" in stack
        if "INACTIVE_UNIT" in overrides:
            assert "Graphical service is not active: bt-daemon.service" in result.stdout
        if expected:
            assert "Recording the update baseline" not in result.stdout
print("rebuild source-identity, argument guard, and service recovery tests passed")
