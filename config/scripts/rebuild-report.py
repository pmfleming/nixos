"""Read-only build diagnostics and private, bounded rebuild history."""
import fcntl
from itertools import takewhile
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def error_excerpt(text):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^(?:error:|fatal:)", line):
            block = [line, *takewhile(lambda item: item.startswith(" "), lines[index + 1:index + 12])]
            drv = re.search(r"/nix/store/[^\s'\"]+\.drv", line)
            if drv:
                block.append("Inspect: nix log " + drv[0])
            return "\n".join(block)[:4000]
    return None


def atomic_json_lines(path, values):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".report-")
    try:
        with os.fdopen(fd, "w") as stream:
            for value in values:
                stream.write(json.dumps(value, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_json_lines(path, [value])


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
        atomic_json_lines(history, entries[-1000:])
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


def nix_output(*arguments, input=None):
    """Telemetry is best-effort; it must never change the deployment result."""
    try:
        return subprocess.check_output(
            ["nix", *arguments], input=input, text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return None


def closure_bytes(system):
    if not system:
        return None
    try:
        return int((nix_output("path-info", "--closure-size", system) or "").split()[-1])
    except (ValueError, IndexError):
        return None


def copied_bytes(paths):
    if not paths:
        return None
    try:
        values = json.loads(nix_output("path-info", "--json", "--stdin", input="\n".join(paths) + "\n"))
        entries = values.values() if isinstance(values, dict) else values
        return sum(entry.get("narSize", 0) or 0 for entry in entries)
    except (ValueError, TypeError, AttributeError):
        return None


def human_bytes(value, signed=False):
    # Preserve coreutils' upward rounding and unit promotion at boundaries.
    formatted = subprocess.check_output(
        ["numfmt", "--to=iec-i", "--suffix=B", "--format=%.1f", "--", str(value)], text=True).strip()
    return ("+" if signed and value >= 0 else "") + formatted


def human_duration(seconds):
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    parts = [f"{seconds}s"]
    if hours or minutes:
        parts.insert(0, f"{minutes}m")
    if hours:
        parts.insert(0, f"{hours}h")
    return " ".join(parts)


def system_summary(before, after):
    if not before or not after:
        return None
    if before == after:
        return f"unchanged ({Path(after).name})"
    return f"{Path(before).name} -> {Path(after).name}"


def store_summary(before):
    try:
        usage = shutil.disk_usage("/nix/store")
    except OSError:
        return None
    change = "" if before is None else human_bytes(usage.used - before, signed=True) + " used; "
    return change + human_bytes(usage.free) + " free"


def print_summary(record, store_before):
    print(f"\n=== REBUILD {record['outcome']} ({human_duration(record['finished_at'] - record['started_at'])}) ===")
    if record["exit_code"]:
        print(f"Failed at:  {record['failed_stage']} (exit {record['exit_code']})")
    copied = record["store_paths_copied"]
    work = f"{len(record['derivations_attempted'])} derivations attempted; {len(copied)} store paths copied"
    size = copied_bytes(copied)
    if size is not None:
        work += f" ({human_bytes(size)})"
    closure = record["closure_after"]
    if closure is not None:
        closure = human_bytes(closure)
        if record["closure_delta"] is not None:
            closure += f" ({human_bytes(record['closure_delta'], signed=True)})"
    fields = [
        ("Nix work", work), ("Closure", closure), ("Nix store", store_summary(store_before)),
        ("System", system_summary(record["system_before"], record["system_after"])),
        ("Session", record["session"]), ("Baseline", record["baseline"]), ("Log", record["log"]),
    ]
    for label, value in fields:
        if value is not None and value != "not reached":
            print(f"{label + ':':12}{value}")
    print("Stages:")
    for stage in record["stages"]:
        print(f"  {stage['seconds']:7.2f}s  {stage['name']}")
    if record["error"]:
        print("Error: " + record["error"])


def deployment_outcome(status, baseline):
    if status:
        return "FAILED"
    return "SUCCESS WITH WARNINGS" if baseline.startswith("not approved ") else "SUCCESS"


def finish(record, stage_file):
    text = Path(record["log"]).read_text(errors="replace")
    record.update(
        schema_version=1, status="failed" if record["exit_code"] else "completed",
        outcome=deployment_outcome(record["exit_code"], record["baseline"]),
        stages=[json.loads(line) for line in Path(stage_file).read_text().splitlines()],
        error=error_excerpt(text) if record["exit_code"] else None,
        derivations_attempted=sorted(set(re.findall(r"^building '([^']+\.drv)'", text, re.M))),
        derivations_built=None,  # Text events don't prove successful completion.
        store_paths_copied=sorted(set(re.findall(r"^copying path '([^']+)'", text, re.M))),
        closure_after=closure_bytes(record["system_after"]),
    )
    before, after = record["closure_before"], record["closure_after"]
    record["closure_delta"] = None if before is None or after is None else after - before
    print_summary(record, record.pop("store_used_before"))
    save(record, Path(record["log"]).parent)
    if record["system_before"] and record["system_after"] and record["system_before"] != record["system_after"]:
        print("\nPackage changes:")
        difference = nix_output("store", "diff-closures", record["system_before"], record["system_after"])
        print(difference if difference is not None else "  (closure diff unavailable)")


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
    finish(json.load(sys.stdin), sys.argv[1])


if __name__ == "__main__":
    main()
