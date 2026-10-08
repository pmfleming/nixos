"""Capture rebuild approval identity from the actual frozen configuration.

Only /etc/nixos identity gates approval. Dirty sibling worktrees remain supported.
The native local-build CLI owns graph discovery and snapshotting; this module
owns the manifest passed to the privileged updater under the deployment lock.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


def git(root, *args):
    return subprocess.run(
        ["git", "-c", f"safe.directory={root}", "-C", str(root), *args],
        check=True, stdout=subprocess.PIPE,
    ).stdout


def file_identity(path):
    if path.is_symlink():
        return ["symlink", os.readlink(path)]
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError(f"unsupported configuration file: {path}")
    return ["file", bool(path.stat().st_mode & 0o111), hashlib.sha256(path.read_bytes()).hexdigest()]


def configuration_identity(root, tracked=False):
    if tracked:
        names = {os.fsdecode(name) for name in git(root, "ls-files", "--cached", "-z").split(b"\0") if name}
    else:
        names = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file() or path.is_symlink()}
    entries = {}
    for name in sorted(names - {"flake.lock"}):
        value = file_identity(root / name)
        if value is not None:
            entries[name] = value
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def revision(root):
    return git(root, "rev-parse", "--verify", "HEAD").decode().strip()


def clean_configuration(root):
    return not git(root, "status", "--porcelain=v1", "--untracked-files=all", "--", ".", ":(exclude)flake.lock")


def matches_configuration(root, identity):
    return (
        revision(root) == identity["revision"]
        and clean_configuration(root)
        and configuration_identity(root, tracked=True) == identity["configuration"]
        and file_identity(root / "flake.lock") == identity["lock"]
    )


def capture(root, frozen, before_revision):
    identity = {
        "version": 1,
        "revision": before_revision,
        "configuration": configuration_identity(frozen),
        "lock": file_identity(frozen / "flake.lock"),
    }
    identity["eligible"] = matches_configuration(root, identity)
    return identity


def verify(root, manifest):
    identity = json.loads(manifest.read_text())
    if identity.get("version") != 1 or not identity.get("eligible"):
        raise ValueError("baseline not approved: " + identity.get(
            "approvalBlocker", "configuration was dirty or changed during capture"))
    if not matches_configuration(root, identity):
        raise ValueError("baseline not approved: sources changed during build")
    lock = identity["lock"]
    if not lock or lock[0] != "file":
        raise ValueError("baseline not approved: missing regular configuration lock file")
    # Return captured values, not a second read of the mutable checkout. If an
    # edit occurs after verification, the updater's next baseline check rejects it.
    return {"revision": identity["revision"], "lockHash": lock[2]}


class NativeHelper:
    def __init__(self, path):
        self.path = path.resolve()

    def run(self, *arguments):
        return subprocess.run([str(self.path), *map(str, arguments)],
                              check=True, stdout=subprocess.PIPE, text=True).stdout

    def preflight(self, root):
        return json.loads(self.run("preflight", root))

    def prepare(self, root, destination):
        return json.loads(self.run("prepare", root, destination, "--capture-root"))

    def remote_lock(self, root, path):
        # Never let pruning modify either captured tree or the live lock.
        with tempfile.TemporaryDirectory(prefix="rebuild-remote-lock-") as temporary:
            lock = Path(temporary) / "flake.lock"
            lock.write_bytes(path.read_bytes())
            self.run("prune-lock", root, lock)
            return json.loads(lock.read_text())


def remote_lock_identity(helper, root, path):
    if not path.exists():
        return None
    remote = helper.remote_lock(root, path)
    return hashlib.sha256(json.dumps(remote, sort_keys=True).encode()).hexdigest()


def prepare(helper, root, destination, manifest):
    before_revision = revision(root)
    result = helper.prepare(root, destination)
    original = destination / ".approval-root"
    frozen = destination / "root"
    if (result.get("originalRoot") != str(original)
            or result.get("flake") != "path:" + str(frozen)):
        raise ValueError("local-build did not return the captured configuration worktree")
    captured = capture(root, original, before_revision)
    captured["remoteLock"] = remote_lock_identity(helper, original, original / "flake.lock")
    if captured["remoteLock"] != remote_lock_identity(helper, original, frozen / "flake.lock"):
        captured["eligible"] = False
        captured["approvalBlocker"] = "remote pins changed during snapshot resolution; update the remote lock and rebuild"
    manifest.write_text(json.dumps(captured, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    child = commands.add_parser("prepare")
    child.add_argument("helper", type=Path)
    child.add_argument("root", type=Path)
    child.add_argument("destination", type=Path)
    child.add_argument("manifest", type=Path)
    child = commands.add_parser("preflight")
    child.add_argument("helper", type=Path)
    child.add_argument("root", type=Path)
    child = commands.add_parser("verify")
    child.add_argument("root", type=Path)
    child.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        result = prepare(NativeHelper(args.helper), args.root.resolve(), args.destination.resolve(), args.manifest)
    elif args.command == "preflight":
        result = NativeHelper(args.helper).preflight(args.root.resolve())
    else:
        result = verify(args.root.resolve(), args.manifest)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
