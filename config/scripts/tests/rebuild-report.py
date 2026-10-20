"""No Nix/system effects: diagnostic extraction and concurrent history writers."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

helper = Path(__file__).resolve().parents[1] / "rebuild-report.py"
spec = importlib.util.spec_from_file_location("report", helper)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
assert "nix log /nix/store/a.drv" in report.error_excerpt("error: Cannot build '/nix/store/a.drv'.\n       Reason: builder failed\nerror: aggregate")
assert report.error_excerpt("all good") is None
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    log = root / "build.log"
    log.write_text("error: test\n")
    stages = root / "stages"
    stages.write_text('{"name":"test","seconds":0.1}\n')
    children = []
    for index in range(8):
        record = {"started_at": index, "exit_code": 1, "log": str(log)}
        child = subprocess.Popen([sys.executable, str(helper), str(stages)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        child.stdin.write(json.dumps(record).encode())
        child.stdin.close()
        children.append(child)
    assert all(child.wait() == 0 for child in children)
    assert len((root / "history.jsonl").read_text().splitlines()) == 8
    assert json.loads((root / "latest-run.json").read_text())["started_at"] == 7
print("rebuild report tests passed")
