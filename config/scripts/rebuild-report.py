"""Read-only build diagnostics and private, bounded rebuild history."""
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile


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


def main():
    record = json.load(sys.stdin)
    record["schema_version"] = 1
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
