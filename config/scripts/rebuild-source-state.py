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
        raise ValueError("baseline not approved: " + identity.get(
            "approvalBlocker", "configuration was dirty or changed during capture"))
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


def remote_lock_identity(helper, path, local_names):
    if not path.exists():
        return None
    remote = helper.prune_lock(json.loads(path.read_text()), local_names)
    return hashlib.sha256(json.dumps(remote, sort_keys=True).encode()).hexdigest()


def prepare(helper, root, destination, manifest):
    snapshot = helper.snapshot
    captured = None
    local_names = []
    frozen_root = None

    def capture_snapshot(source, target):
        nonlocal captured, local_names, frozen_root
        before = revision(root) if source == root else None
        snapshot(source, target)
        if source == root:
            # Before local-build rewrites the disposable flake.lock.
            captured = capture(root, target, before)
            frozen_root = target
            local_names = [name for name, spec in helper.read_inputs(target).items()
                           if helper.local_path(spec, root) is not None]
            captured["remoteLock"] = remote_lock_identity(helper, target / "flake.lock", local_names)

    helper.snapshot = capture_snapshot
    try:
        result = helper.prepare(root, destination)
    finally:
        helper.snapshot = snapshot
    if captured is None:
        raise ValueError("local-build did not capture the configuration worktree")
    if captured["remoteLock"] != remote_lock_identity(helper, frozen_root / "flake.lock", local_names):
        captured["eligible"] = False
        captured["approvalBlocker"] = "remote pins changed during snapshot resolution; update the remote lock and rebuild"
    manifest.write_text(json.dumps(captured, indent=2) + "\n")
    return result


def preflight(helper, root):
    """Inspect the live graph for diagnostics only; prepare still revalidates it."""
    definitions = {}
    problems = []
    walked = set()

    def inspect(source):
        if source in definitions:
            return definitions[source]
        definitions[source] = None
        try:
            top = Path(os.fsdecode(git(source, "rev-parse", "--show-toplevel")).strip()).resolve()
            if top != source:
                raise ValueError(f"not a repository root: {source}")
            untracked = git(source, "ls-files", "--others", "--exclude-standard", "-z")
            if untracked:
                names = [os.fsdecode(name) for name in untracked.split(b"\0") if name]
                problems.append(f"Untracked files in {source}:\n" + "\n".join(f"  {name!r}" for name in names))
            definitions[source] = helper.read_inputs(source)
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            problems.append(f"Cannot inspect {source}: {error}")
        return definitions[source]

    def walk(source, overlay, ancestors):
        if source in ancestors:
            problems.append(f"Local input cycle at {source}")
            return
        key = (source, json.dumps(overlay, sort_keys=True))
        if key in walked:
            return
        walked.add(key)
        inputs = inspect(source)
        if inputs is None:
            return
        for name, spec in helper.merge(inputs, overlay).items():
            if "follows" in spec:
                continue
            try:
                child = helper.local_path(spec, source)
                if child is not None:
                    walk(child, spec.get("inputs", {}), ancestors | {source})
            except (ValueError, OSError) as error:
                problems.append(f"Cannot inspect {source}/{name}: {error}")

    walk(root, {}, set())
    if problems:
        raise ValueError("Local worktree preflight failed:\n\n" + "\n\n".join(problems)
                         + "\n\nAdd or ignore untracked files explicitly; rebuild never changes Git tracking.")
    return {"repositories": [str(source) for source in definitions]}


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
        result = prepare(load_helper(args.helper), args.root.resolve(), args.destination.resolve(), args.manifest)
    elif args.command == "preflight":
        result = preflight(load_helper(args.helper), args.root.resolve())
    else:
        result = verify(args.root.resolve(), args.manifest)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
