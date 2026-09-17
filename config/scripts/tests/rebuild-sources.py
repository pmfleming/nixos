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
    subprocess.run(["git", "init", "-q", str(flake)], check=True)
    subprocess.run(["git", "-C", str(flake), "add", "."], check=True)
    binaries = root / "bin"
    binaries.mkdir()
    events = root / "events"

    def executable(name, text):
        path = binaries / name
        path.write_text(f"#!{shutil.which('bash')}\nset -eu\n" + text)
        path.chmod(0o755)
        return path

    sudo = executable("sudo", 'if [ "$1" = -v ]; then exit 0; fi\nexec "$@"\n')
    executable("systemctl", 'case "$*" in *is-active*) exit 1;; *) exit 0;; esac\n')
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
''')
    helper = root / "local-build.py"
    helper.write_text('''import json, pathlib, shutil, sys
assert sys.argv[1] == "prepare"
source, destination = map(pathlib.Path, sys.argv[2:4])
staged = destination / "root"
staged.mkdir(parents=True)
shutil.copyfile(source / "flake.nix", staged / "flake.nix")
# Simulate an edit after capture: neither check nor switch may consume it.
(source / "flake.nix").write_text("later edit\\n")
print(json.dumps({"flake": "path:" + str(staged)}))
''')
    rendered = (scripts / "rebuild.sh").read_text()
    for old, new in {
        "@CONFIG_DIRECTORY@": str(flake),
        "@FLAKE_ATTR@": "thinkpad",
        "@LOCAL_BUILD_HELPER@": str(helper),
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
                       NIXOS_DEPLOYMENT_LOCK_FILE=str(lock), EVENTS=str(events))
    environment.pop("NIXOS_LOCAL_BUILD_HELPER", None)
    environment.pop("NIXOS_DEPLOYMENT_LOCK_HELPER", None)
    result = subprocess.run(["bash", str(script)], env=environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    checked, switched = events.read_text().splitlines()
    assert switched == "switch " + checked.removeprefix("check ") + "#thinkpad"
    assert (flake / "flake.nix").read_text() == "later edit\n"
    assert not (flake / "flake.lock").exists()
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
print("rebuild source-identity and override-guard tests passed")
