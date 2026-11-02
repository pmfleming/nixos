"""No Nix/system effects: diagnostic extraction and concurrent history writers."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

helper = Path(__file__).resolve().parents[1] / "rebuild-report.py"
spec = importlib.util.spec_from_file_location("report", helper)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
assert "nix log /nix/store/a.drv" in report.error_excerpt("error: Cannot build '/nix/store/a.drv'.\n       Reason: builder failed\nerror: aggregate")
assert report.error_excerpt("all good") is None
assert report.error_excerpt("noise\nfatal: first\n detail\nstop\n ignored") == "fatal: first\n detail"
assert len(report.error_excerpt("error: first\n" + " detail\n" * 20).splitlines()) == 12
assert len(report.error_excerpt("error: " + "x" * 5000)) == 4000
assert report.human_duration(0) == "0s"
assert report.human_duration(61) == "1m 1s"
assert report.human_duration(3601) == "1h 0m 1s"
assert report.human_bytes(1024) == "1.0KiB"
assert report.human_bytes(1025) == "1.1KiB"
assert report.human_bytes(1048575) == "1.0MiB"
assert report.human_bytes(-1024, signed=True) == "-1.0KiB"
assert report.human_bytes(0, signed=True) == "+0.0B"
with patch.object(report.subprocess, "check_output", return_value=""):
    assert report.nix_output("store", "diff-closures", "/before", "/after") == ""
with patch.object(report.subprocess, "check_output", side_effect=OSError("missing nix")):
    assert report.nix_output("store", "diff-closures", "/before", "/after") is None
    assert report.closure_bytes("/system") is None
    assert report.copied_bytes(["/path"]) is None
with patch.object(report, "nix_output", return_value='{"/path":{"narSize":1024}}'):
    assert report.copied_bytes(["/path"]) == 1024
with patch.object(report, "nix_output", return_value='[{"narSize":1024},{"narSize":null}]'):
    assert report.copied_bytes(["/path"]) == 1024


def record_for(log, started=0):
    return dict(started_at=started, finished_at=started + 61, exit_code=1,
                failed_stage="test", log=str(log), system_before="", system_after="",
                baseline="not reached", session="not reached", deployed=False,
                closure_before=None, store_used_before=None)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    destination = root / "atomic.json"
    report.atomic_json(destination, {"old": True})
    with patch.object(report.os, "replace", side_effect=OSError("publication failed")):
        try:
            report.atomic_json_lines(destination, [{"new": True}])
        except OSError:
            pass
        else:
            raise AssertionError("publication failure was swallowed")
    assert json.loads(destination.read_text()) == {"old": True}
    assert destination.stat().st_mode & 0o777 == 0o600
    assert not list(root.glob(".report-*"))
    log = root / "build.log"
    log.write_text("error: test\n")
    stages = root / "stages"
    stages.write_text('{"name":"test","seconds":0.1}\n')
    children = []
    for index in range(8):
        record = record_for(log, index)
        child = subprocess.Popen([sys.executable, str(helper), str(stages)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        child.stdin.write(json.dumps(record).encode())
        child.stdin.close()
        children.append(child)
    assert all(child.wait() == 0 for child in children)
    assert len((root / "history.jsonl").read_text().splitlines()) == 8
    assert json.loads((root / "latest-run.json").read_text())["started_at"] == 7
    abandoned = root / "rebuild-abandoned.running.log"
    abandoned.write_text("==> interrupted stage\n")
    marker = Path(str(abandoned) + ".run.json")
    pending = {"started_at": 9, "pid": 0, "boot_id": "old", "process_start": "0", "log": str(abandoned)}
    marker.write_text(json.dumps(pending))
    report.recover(root)
    assert not marker.exists()
    assert json.loads((root / "latest-run.json").read_text())["outcome"] == "INTERRUPTED"
    marker.write_text(json.dumps(pending))
    report.recover(root)
    assert len((root / "history.jsonl").read_text().splitlines()) == 9
    history = root / "history.jsonl"
    history.write_text('{}\n' * 1001 + '{torn append')
    report.save({"started_at": 10, "log": str(log)}, root)
    entries = [json.loads(line) for line in history.read_text().splitlines()]
    assert len(entries) == 1000 and entries[-1]["started_at"] == 10
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    log = root / "build.log"
    log.write_text("building '/nix/store/a.drv'...\nbuilding '/nix/store/a.drv'...\n"
                   "copying path '/nix/store/b'...\nerror: test\n detail\n")
    stages = root / "stages"
    stages.write_text('{"name":"test","seconds":0.1}\n')
    for index, (status, baseline, outcome) in enumerate([
        (1, "not reached", "FAILED"), (0, "recorded", "SUCCESS"),
        (0, "not approved (dirty)", "SUCCESS WITH WARNINGS"),
    ]):
        record = record_for(log, index)
        record.update(exit_code=status, baseline=baseline, closure_before=2048,
                      system_before="/nix/store/before", system_after="/nix/store/after")
        output = io.StringIO()
        with redirect_stdout(output), patch.object(report, "closure_bytes", return_value=1024), \
                patch.object(report, "copied_bytes", return_value=1024), \
                patch.object(report.shutil, "disk_usage", side_effect=OSError("unavailable")), \
                patch.object(report, "nix_output", return_value="package diff"):
            report.finish(record, stages)
        saved = json.loads((root / "latest-run.json").read_text())
        assert saved["outcome"] == outcome
        assert saved["closure_delta"] == -1024
        assert saved["derivations_attempted"] == ["/nix/store/a.drv"]
        assert saved["derivations_built"] is None
        assert saved["store_paths_copied"] == ["/nix/store/b"]
        assert "store_used_before" not in saved
        assert bool(saved["error"]) == bool(status)
        text = output.getvalue()
        assert f"=== REBUILD {outcome} (1m 1s) ===" in text
        assert "1 derivations attempted; 1 store paths copied (1.0KiB)" in text
        assert "Closure:    1.0KiB (-1.0KiB)" in text
        assert "Nix store:" not in text
        assert "package diff" in text
print("rebuild report tests passed")
