"""Exercise the real rebuild control flow with fake Nix/systemd/sudo commands."""
import shutil
import json
import pwd
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1]).resolve()
driver = Path(sys.argv[2]).resolve()
template = json.loads(Path(sys.argv[3]).read_text())
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    rendered_scripts = root / "scripts"
    subprocess.run(["bash", str(scripts / "tests/render-deployment.sh"), str(scripts), str(rendered_scripts)], check=True)
    flake = root / "flake"
    flake.mkdir()
    (flake / "flake.nix").write_text("before\n")
    (flake / "flake.lock").write_text("{}\n")
    subprocess.run(["git", "init", "-q", str(flake)], check=True)
    subprocess.run(["git", "-C", str(flake), "add", "."], check=True)
    subprocess.run(["git", "-C", str(flake), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "commit", "-qm", "initial"], check=True)
    initial_revision = subprocess.check_output(["git", "-C", str(flake), "rev-parse", "HEAD"], text=True).strip()
    binaries = root / "bin"
    binaries.mkdir()
    events = root / "events"

    def executable(name, text):
        path = binaries / name
        path.write_text(f"#!{shutil.which('bash')}\nset -eu\n" + text)
        path.chmod(0o755)
        return path

    sudo = executable("sudo", '''
printf '%s\\n' "$*" >> "$SUDO_EVENTS"
if [ "$1" = -v ]; then
  if [ "${LATE_UNTRACKED:-0}" = 1 ]; then touch "$FLAKE_DIR/late.txt"; fi
  exit "${AUTH_STATUS:-0}"
fi
exec "$@"
''')
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
if [ "$1 $2" = 'flake check' ]; then
  [ "$4" = --no-update-lock-file ]
  [ "$5" = --no-build ]
  printf 'evaluate %s\\n' "$3" >> "$GATE_EVENTS"
  # Edits during evaluation must not affect checks/switch or gain approval.
  case "${MUTATION:-edit}" in
    edit|commit) printf 'later edit\\n' > "$FLAKE_DIR/flake.nix" ;;
    lock) printf '{"changed": true}\\n' > "$FLAKE_DIR/flake.lock" ;;
  esac
  if [ "${MUTATION:-edit}" = commit ]; then
    git -C "$FLAKE_DIR" -c user.name=Test -c user.email=test@example.invalid commit -qam 'changed during build'
  fi
  exit "${EVAL_STATUS:-0}"
fi
[ "$1" = build ]
[ "$3" = --no-update-lock-file ]
source=${2#path:}
source=${source%#*}
[ "$(< "$source/flake.nix")" = before ]
case "$2" in
  *#rebuildPreflight)
    [ "$4" = --no-link ]
    printf 'preflight path:%s\\n' "$source" >> "$GATE_EVENTS"
    exit "${PREFLIGHT_STATUS:-0}" ;;
  *#rebuildChecks)
    [ "$4" = --out-link ]
    printf 'check path:%s\\n' "$source" >> "$EVENTS"
    printf '%s\\n' "${@:6}" > "$CHECK_ARGUMENTS"
    if [ "${CHECK_STATUS:-0}" != 0 ]; then exit "$CHECK_STATUS"; fi
    ln -s "/nix/store/${CACHE_TARGET:-fake-check-cache-$$}" "$5" ;;
  *) exit 99 ;;
esac
''')
    executable("nixos-rebuild", '''
[ "$1" = switch ]
[ "$2" = --flake ]
[ "$4" = --no-update-lock-file ]
source=${3#path:}
source=${source%#thinkpad}
[ "$(< "$source/flake.nix")" = before ]
printf 'switch %s\n' "$3" >> "$EVENTS"
printf '%s\\n' "${@:5}" > "$SWITCH_ARGUMENTS"
exit "${SWITCH_STATUS:-0}"
''')
    helper = root / "local-build"
    helper.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, shutil, subprocess, sys

command, source, *arguments = sys.argv[1:]
source = pathlib.Path(source)
if command in ("preflight", "prepare"):
    untracked = subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard"])
    if untracked:
        sys.exit("Untracked files in " + str(source) + ": " + untracked.decode() + "; Git-add or ignore untracked files")
if command == "preflight":
    assert not arguments
    print(json.dumps({"repositories": [str(source)]}))
elif command == "prepare":
    destination, flag = arguments
    assert flag == "--capture-root"
    destination = pathlib.Path(destination)
    staged = destination / "root"
    original = destination / ".approval-root"
    pathlib.Path(SNAPSHOT_PATH).write_text(str(destination.parent))
    for target in (staged, original):
        target.mkdir(parents=True)
        for name in ("flake.nix", "flake.lock"):
            shutil.copyfile(source / name, target / name)
    print(json.dumps({"flake": "path:" + str(staged), "originalRoot": str(original)}))
elif command == "prune-lock":
    assert len(arguments) == 1
else:
    sys.exit("unexpected native helper command: " + command)
''')
    helper.write_text(helper.read_text().replace("SNAPSHOT_PATH", repr(str(root / "snapshot-path"))))
    helper.chmod(0o755)
    # Native test-only driver uses explicit private configuration, not production
    # environment overrides or the retired shell/Python approval implementation.
    approval = root / "approval"
    shutil.copyfile(driver, approval)
    approval.chmod(0o755)
    approval.with_suffix(".effect.json").write_text(json.dumps({"root": str(root), "role": "worker"}))
    active_system = root / "active-system"
    (active_system / "bin").mkdir(parents=True)
    switch_program = active_system / "bin/switch-to-configuration"
    switch_program.write_text("#!/bin/sh\nexit 0\n")
    switch_program.chmod(0o755)
    updater_state = root / "updater-state"
    template.update(flake_directory=str(flake), state_directory=str(updater_state),
                    ai_state_directory=str(root / "ai"),
                    username=pwd.getpwuid(os.geteuid()).pw_name,
                    local_build_helper=str(helper),
                    deployment_lock=str(rendered_scripts / "deployment.lock"),
                    active_system=str(active_system), system_profile=str(root / "system-profile"),
                    runtime_path=str(binaries) + ":" + os.environ["PATH"])
    (root / "config.json").write_text(json.dumps(template))
    rendered = (rendered_scripts / "rebuild.sh").read_text()
    for old, new in {
        "@CONFIG_DIRECTORY@": str(flake),
        "@FLAKE_ATTR@": "thinkpad",
        "@SOURCE_STATE_HELPER@": str(approval),
        "@APPROVAL_HELPER@": str(approval),
        "/run/wrappers/bin/sudo": str(sudo),
    }.items():
        rendered = rendered.replace(old, new)
    script = root / "rebuild.sh"
    script.write_text(rendered)
    lock = rendered_scripts / "deployment.lock"
    environment = dict(os.environ, PATH=str(binaries) + ":" + os.environ["PATH"],
                       HOME=str(root), XDG_STATE_HOME=str(root / "state"),
                       EVENTS=str(events),
                       GATE_EVENTS=str(root / "gate-events"),
                       STACK_EVENTS=str(root / "stack-events"), SUDO_EVENTS=str(root / "sudo-events"),
                       CHECK_ARGUMENTS=str(root / "check-arguments"), SWITCH_ARGUMENTS=str(root / "switch-arguments"),
                       SNAPSHOT_PATH=str(root / "snapshot-path"), FLAKE_DIR=str(flake))
    for name in ("MUTATION", "AUTH_STATUS", "LATE_UNTRACKED", "CHECK_STATUS", "SWITCH_STATUS",
                 "EVAL_STATUS", "PREFLIGHT_STATUS", "CACHE_TARGET",
                 "GRAPHICAL_STATUS", "INACTIVE_UNIT", "DAEMON_RESTART_STATUS", "NIXOS_UPDATE_LIB_ONLY"):
        environment.pop(name, None)
    environment.pop("NIXOS_LOCAL_BUILD_HELPER", None)
    environment.pop("NIXOS_DEPLOYMENT_LOCK_HELPER", None)
    result = subprocess.run(["bash", str(script)], env=environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    checked, switched = events.read_text().splitlines()
    assert switched == "switch " + checked.removeprefix("check ") + "#thinkpad"
    frozen = checked.removeprefix("check ")
    assert (root / "gate-events").read_text().splitlines() == [
        "evaluate " + frozen, "preflight " + frozen,
    ]
    assert (root / "check-arguments").read_text().splitlines() == ["--max-jobs", "2", "--cores", "8"]
    cache = root / "state/nixos-rebuild/check-cache"
    assert len(list(cache.glob("entry-*/checks"))) == 1
    assert (flake / "flake.nix").read_text() == "later edit\n"
    assert (flake / "flake.lock").read_text() == "{}\n"
    assert "baseline not approved: sources changed during build" in result.stdout
    assert "REBUILD SUCCESS WITH WARNINGS" in result.stdout
    logs = root / "state/nixos-rebuild"
    assert (logs / "latest.log").resolve().name.endswith(".success.log")
    assert "SUCCESS WITH WARNINGS" in (logs / "latest.log").read_text()
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
        failed_log = (logs / "latest.log").resolve()
        assert failed_log.name.endswith(".failed.log")
        assert failed_log == (logs / "latest-failed.log").resolve()
        assert "Failed at:  Validating rebuild arguments (exit 2)" in failed_log.read_text()

    for arguments in (["-L", "--show-trace", "--cores=2", "-j4"],
                      ["--max-jobs", "auto", "--cores", "0", "--offline"],
                      ["--keep-going"]):
        (flake / "flake.nix").write_text("before\n")
        result = subprocess.run(["bash", str(script), *arguments],
                                env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        check_arguments = (root / "check-arguments").read_text().splitlines()
        switch_arguments = (root / "switch-arguments").read_text().splitlines()
        assert check_arguments == switch_arguments
        assert "--cores" in switch_arguments and "--max-jobs" in switch_arguments
        assert ("--keep-going" in check_arguments) == ("--keep-going" in arguments)
        if "-j4" in arguments:
            assert check_arguments[-4:] == ["--max-jobs", "4", "--cores", "2"]
        assert len(list(cache.glob("entry-*/checks"))) == 2, "check cache is not bounded"
    before_sudo = (root / "sudo-events").read_text()
    with (logs / "rebuild.lock").open("r+") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(["bash", str(script)], env=environment, text=True, capture_output=True)
    assert result.returncode == 75, result.stdout + result.stderr
    assert "This log records only the rejected attempt" in result.stdout
    assert "see " + str(logs / "latest.log") not in result.stdout
    assert "Acquiring the interactive rebuild lock (exit 75)" in (logs / "latest.log").read_text()
    assert (root / "sudo-events").read_text() == before_sudo

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
    def scenario(**overrides):
        # This repository exists only inside TemporaryDirectory.
        subprocess.run(["git", "-C", str(flake), "reset", "--hard", "-q", initial_revision], check=True)
        events.write_text("")
        (root / "gate-events").write_text("")
        (root / "snapshot-path").unlink(missing_ok=True)
        (root / "stack-events").write_text("")
        result = subprocess.run(["bash", str(script)], env=dict(environment, **overrides),
                                text=True, capture_output=True, timeout=20)
        snapshot_marker = root / "snapshot-path"
        if snapshot_marker.exists():
            assert not Path(snapshot_marker.read_text()).exists(), "snapshot leaked on exit"
        return result

    result = scenario(MUTATION="none", NIXOS_LOCAL_BUILD_HELPER="/missing-helper",
                      NIXOS_DEPLOYMENT_LOCK_HELPER="/missing-lock-helper",
                      NIXOS_DEPLOYMENT_LOCK_FILE="/missing-lock")
    assert result.returncode == 0 and "Baseline:   recorded" in result.stdout, result.stdout + result.stderr
    assert "SUCCESS WITH WARNINGS" not in result.stdout
    assert (updater_state / "approved-revision").read_text().strip() == initial_revision
    assert (updater_state / "approved-system").read_text().strip() == str(active_system)
    # Repeated cache hits must not evict the previous distinct successful set.
    abandoned = cache / "entry-000-abandoned"
    abandoned.mkdir()
    for _ in range(2):
        result = scenario(MUTATION="none", CACHE_TARGET="stable-check-set")
        assert result.returncode == 0, result.stdout + result.stderr
        targets = [os.readlink(path) for path in cache.glob("entry-*/checks")]
        assert len(targets) == len(set(targets)) == 2
        assert targets.count("/nix/store/stable-check-set") == 1
    assert not abandoned.exists(), "abandoned cache attempt was not cleaned"
    approved = {name: (updater_state / name).read_bytes()
                for name in ("approval.json", "approved-revision", "approved-system", "applied-lock-hash")}
    for mutation in ("edit", "commit", "lock"):
        result = scenario(MUTATION=mutation)
        assert result.returncode == 0 and "baseline not approved: sources changed during build" in result.stdout, result.stdout
        for name, contents in approved.items():
            assert (updater_state / name).read_bytes() == contents
    # Approval may neither overwrite metadata nor recover an unrelated pending
    # transaction. Native guards reject a legacy journal before source inspection.
    transaction = updater_state / "apply-transaction"
    transaction.mkdir()
    (transaction / "sentinel").write_text("retain\n")
    for mutation in ("edit", "commit", "lock"):
        result = scenario(MUTATION=mutation)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "legacy transaction present" in result.stdout
        assert "SUCCESS WITH WARNINGS" in result.stdout
        assert "Automatic rollback" not in result.stdout
        assert list(transaction.iterdir()) == [transaction / "sentinel"]
        assert (transaction / "sentinel").read_text() == "retain\n"
        for name, contents in approved.items():
            assert (updater_state / name).read_bytes() == contents
    shutil.rmtree(transaction)
    journal = updater_state / "transaction.json"
    journal.write_text("pending transaction must not be parsed or recovered by approval")
    result = scenario(MUTATION="none")
    assert result.returncode == 0 and "recover pending transaction before approving" in result.stdout, result.stdout
    assert journal.read_text() == "pending transaction must not be parsed or recovered by approval"
    for name, contents in approved.items():
        assert (updater_state / name).read_bytes() == contents
    journal.unlink()

    with (updater_state / "update.lock").open("r+") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = scenario(MUTATION="none")
    assert result.returncode == 0 and "SUCCESS WITH WARNINGS" in result.stdout
    assert "Another NixOS update operation" in result.stdout

    for overrides, expected, stage in [
        ({"AUTH_STATUS": "9"}, 9, "Authorizing the generation switch"),
        ({"EVAL_STATUS": "12"}, 12, "Evaluating the frozen deployment graph"),
        ({"PREFLIGHT_STATUS": "13"}, 13, "Running inexpensive deployment checks"),
        ({"CHECK_STATUS": "11"}, 11, "Running framework, daemon, Shelllist, and configuration checks"),
        ({"LATE_UNTRACKED": "1"}, 1, "Snapshotting current local worktrees"),
    ]:
        retained = sorted(str(path) for path in cache.glob("entry-*/checks"))
        result = scenario(**overrides)
        assert result.returncode == expected, result.stdout + result.stderr
        assert sorted(str(path) for path in cache.glob("entry-*/checks")) == retained
        assert len(list(cache.glob("entry-*"))) == 2, "failed cache attempt leaked"
        if "EVAL_STATUS" in overrides or "PREFLIGHT_STATUS" in overrides:
            assert not events.read_text(), "early failure reached expensive checks"
        assert f"Failed at:  {stage} (exit {expected})" in result.stdout
        assert "switch " not in events.read_text(), "failure reached deployment"
        assert "Recording the update baseline" not in result.stdout
        (flake / "late.txt").unlink(missing_ok=True)

    with lock.open("r+") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = scenario()
    assert result.returncode == 75 and "Acquiring the shared deployment lock" in result.stdout
    assert not events.read_text(), "deployment lock contention reached checks or switch"

    result = subprocess.run([str(approval), "approve-current"], env=environment, text=True, capture_output=True)
    assert result.returncode == 1 and "approval requires an absolute manifest path" in result.stderr
    for name, contents in approved.items():
        assert (updater_state / name).read_bytes() == contents
print("rebuild source identity, argument, approval, recovery, logging, and contention tests passed")
