"""Read-only build diagnostics and private, bounded rebuild history."""
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


def error_excerpt(text):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^(?:error:|fatal:)", line):
            block = [line]
            for following in lines[index + 1:index + 12]:
                if not following.startswith(" "):
                    break
                block.append(following)
            drv = re.search(r"/nix/store/[^\s'\"]+\.drv", line)
            if drv:
                block.append("Inspect: nix log " + drv[0])
            return "\n".join(block)[:4000]
    return None


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".report-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save(record, directory):
    # Rejected concurrent attempts also get a record; don't use deployment locks.
    with (directory / "history.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        history = directory / "history.jsonl"
        entries = []
        if history.exists():
            for line in history.read_text().splitlines():
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    pass  # A crash can leave an incomplete last append.
        record["run_id"] = str(record["started_at"]) + ":" + re.sub(r"\.(running|success|failed)\.log$", "", Path(record["log"]).name)
        if any(entry.get("run_id") == record["run_id"] for entry in entries):
            return  # A crash after publication but before marker cleanup.
        entries.append(record)
        # Rewrite under the lock to bound history and discard torn appends.
        fd, temporary = tempfile.mkstemp(dir=directory, prefix=".history-")
        try:
            with os.fdopen(fd, "w") as stream:
                for entry in entries[-1000:]:
                    stream.write(json.dumps(entry, separators=(",", ":")) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, history)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        latest = directory / "latest-run.json"
        try:
            old = json.loads(latest.read_text())
        except (OSError, ValueError):
            old = {}
        if record["started_at"] >= old.get("started_at", 0):
            atomic_json(latest, record)
        if record.get("deployed"):
            atomic_json(directory / "last-deployment.json", record)


def process_alive(record):
    try:
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        stat = Path(f"/proc/{int(record['pid'])}/stat").read_text().rsplit(")", 1)[1].split()
        return boot == record["boot_id"] and stat[0] not in ("Z", "X") and stat[19] == record["process_start"]
    except (OSError, ValueError, KeyError, IndexError):
        return False


def recover(directory):
    for marker in directory.glob("rebuild-*.running.log.run.json"):
        try:
            record = json.loads(marker.read_text())
            log = Path(record["log"])
            if process_alive(record) or log.parent != directory or str(marker) != str(log) + ".run.json":
                continue
            stages = Path(str(log) + ".stages")
            record.update(schema_version=1, exit_code=137, outcome="INTERRUPTED", status="interrupted", finished_at=int(time.time()),
                          deployed=None, baseline="unknown after interruption", error="Process exited without a final report; activation outcome may be unknown.",
                          stages=[json.loads(line) for line in stages.read_text().splitlines()] if stages.exists() else [])
            save(record, directory)
            marker.unlink()
            stages.unlink(missing_ok=True)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"Warning: cannot recover rebuild record {marker}: {error}", file=sys.stderr)


def sources(action, snapshot_path, saved_path, system, detailed=False):
    snapshot = json.loads(Path(snapshot_path).read_text())["sourceManifest"]
    saved_path = Path(saved_path)
    if action == "save":
        atomic_json(saved_path, {"system": system, **snapshot})
        return
    try:
        previous = json.loads(saved_path.read_text())
        if previous.get("system") != system:
            raise ValueError("active system is not the recorded deployment")
    except (OSError, ValueError) as error:
        print(f"Changed since last deploy: unknown ({error})")
        return
    changes = []
    for repo in sorted(previous["sources"].keys() | snapshot["sources"].keys()):
        before, after = previous["sources"].get(repo, {}), snapshot["sources"].get(repo, {})
        names = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        if names:
            changes.append(f"{Path(repo).name} ({len(names)} files)")
            if detailed:
                print(f"  {repo}: " + ", ".join(repr(name) for name in names))
    if previous.get("remote_lock") != snapshot.get("remote_lock"):
        changes.append("remote flake.lock pins")
    print("Changed since last deploy: " + (", ".join(changes) or "none"))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "start":
        _, _, destination, log, pid, started = sys.argv
        stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        recover(Path(destination).parent)
        atomic_json(Path(destination), {"schema_version": 1, "status": "running", "pid": int(pid),
                    "started_at": int(started), "log": log, "process_start": stat[19],
                    "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip()})
        return
    if len(sys.argv) > 1 and sys.argv[1] == "sources":
        sources(*sys.argv[2:6], detailed="--files" in sys.argv[6:])
        return
    record = json.load(sys.stdin)
    record["schema_version"] = 1
    record["status"] = "completed" if record["exit_code"] == 0 else "failed"
    record["stages"] = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
    text = Path(record["log"]).read_text(errors="replace")
    record["error"] = error_excerpt(text) if record["exit_code"] else None
    record["derivations_attempted"] = sorted(set(re.findall(r"^building '([^']+\.drv)'", text, re.M)))
    record["derivations_built"] = None  # Text events don't prove successful completion.
    record["store_paths_copied"] = sorted(set(re.findall(r"^copying path '([^']+)'", text, re.M)))
    print("Stages:")
    for stage in record["stages"]:
        print(f"  {stage['seconds']:7.2f}s  {stage['name']}")
    if record["error"]:
        print("Error: " + record["error"])
    save(record, Path(record["log"]).parent)


if __name__ == "__main__":
    main()
