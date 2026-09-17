"""Capture rebuild approval identity from the actual frozen configuration.

Only /etc/nixos identity gates approval. Dirty sibling worktrees remain supported.
The manifest is passed explicitly to the privileged updater under the existing
 deployment -> updater-state lock order; no shared environment or request file.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

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


def capture(root, frozen, before_revision):
    identity = {
        "version": 1,
        "revision": before_revision,
        "configuration": configuration_identity(frozen),
        "lock": file_identity(frozen / "flake.lock"),
    }
    identity["eligible"] = (
        revision(root) == before_revision
        and clean_configuration(root)
        and configuration_identity(root, tracked=True) == identity["configuration"]
        and file_identity(root / "flake.lock") == identity["lock"]
    )
    return identity


def verify(root, manifest):
    identity = json.loads(manifest.read_text())
    if identity.get("version") != 1 or not identity.get("eligible"):
        raise ValueError("baseline not approved: configuration was dirty or changed during capture")
    if (revision(root) != identity["revision"]
            or not clean_configuration(root)
            or configuration_identity(root, tracked=True) != identity["configuration"]
            or file_identity(root / "flake.lock") != identity["lock"]):
        raise ValueError("baseline not approved: sources changed during build")
    lock = identity["lock"]
    if not lock or lock[0] != "file":
        raise ValueError("baseline not approved: missing regular configuration lock file")
    # Return captured values, not a second read of the mutable checkout. If an
    # edit occurs after verification, the updater's next baseline check rejects it.
    return {"revision": identity["revision"], "lockHash": lock[2]}


def load_helper(path):
    spec = importlib.util.spec_from_file_location("local_build", path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def prepare(helper, root, destination, manifest):
    snapshot = helper.snapshot
    captured = None

    def capture_snapshot(source, target):
        nonlocal captured
        before = revision(root) if source == root else None
        snapshot(source, target)
        if source == root:
            # Before local-build rewrites the disposable flake.lock.
            captured = capture(root, target, before)

    helper.snapshot = capture_snapshot
    try:
        result = helper.prepare(root, destination)
    finally:
        helper.snapshot = snapshot
    if captured is None:
        raise ValueError("local-build did not capture the configuration worktree")
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
    child = commands.add_parser("verify")
    child.add_argument("root", type=Path)
    child.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        result = prepare(load_helper(args.helper), args.root.resolve(), args.destination.resolve(), args.manifest)
    else:
        result = verify(args.root.resolve(), args.manifest)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
