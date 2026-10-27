"""Real Pi observer + separate dashboard, offline; no model calls or worker control.
Run: python3 config/pi/tests/instances-tui.py
"""
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

extension = pathlib.Path(__file__).resolve().parents[1] / "instances" / "index.ts"
launcher = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "pi-instances.sh"
with tempfile.TemporaryDirectory(prefix="pi-instances-tui-") as tmp:
    root = pathlib.Path(tmp)
    (root / "home" / ".pi" / "agent" / "extensions").mkdir(parents=True)
    (root / "home" / ".pi" / "agent" / "extensions" / "instances").symlink_to(extension.parent)
    (root / "agent").mkdir()
    (root / "agent" / "settings.json").write_text(json.dumps({"defaultProvider": "openai-codex", "defaultModel": "gpt-6.1-sol"}))
    registry = root / "registry"
    env = {k: os.environ[k] for k in ("PATH", "LANG") if k in os.environ}
    env.update(HOME=str(root / "home"), TERM="xterm-256color", PI_CODING_AGENT_DIR=str(root / "agent"),
               PI_INSTANCES_DIR=str(registry), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1", PI_TELEMETRY="0")
    base = ["pi", "--no-extensions", "--extension", str(extension), "--no-mcp", "--no-tools", "--no-skills",
            "--no-prompt-templates", "--no-context-files", "--no-approve", "--no-session", "--offline",
            "--provider", "openai-codex", "--model", "gpt-6.1-sol"]
    observed = subprocess.Popen(base + ["--mode", "rpc", "--name", "OBSERVED_PI_FIXTURE"], cwd=root, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    master, slave = pty.openpty()
    def resize(rows, cols):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    resize(42, 140)
    viewer = subprocess.Popen([str(launcher)], cwd=root, env=env,
                              stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()
    def read_for(seconds):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([master], [], [], .1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                output.extend(data)
                assert len(output) < 3 * 1024 * 1024
        return output.decode("utf8", "replace")
    def send(text):
        os.write(master, text.encode())
    def snapshots():
        return [json.loads(p.read_text()) for p in registry.glob("*.json")]
    try:
        initial = read_for(5)
        assert viewer.poll() is None and observed.poll() is None, initial[-5000:]
        assert "Pi instances" in initial and "OBSERVED_PI_FIXTURE" in initial, initial[-9000:]
        records = snapshots()
        worker = next(r for r in records if r["pid"] == observed.pid)
        dashboard = next(r for r in records if r["pid"] == viewer.pid)
        assert worker["sessionId"] != dashboard["sessionId"]
        assert worker["state"] == "idle" and worker["mode"] == "rpc"
        assert dashboard["state"] == "waiting"
        assert worker["toolCount"] == 0 and worker["turns"] == 0
        # Details and narrow-terminal resize do not send prompts or affect the observed Pi.
        send("\r"); read_for(.5)
        resize(9, 24); os.kill(viewer.pid, signal.SIGWINCH); read_for(.5)
        resize(42, 140); os.kill(viewer.pid, signal.SIGWINCH); read_for(.5)
        send("\x1b"); read_for(.5)
        # Explicitly shut down ONLY our fixture observer, not anything discovered by the dashboard.
        observed.stdin.close()
        observed.wait(timeout=8)
        read_for(3)
        start = len(output); send("a"); read_for(1)
        exited = output[start:].decode("utf8", "replace")
        assert "EXITED" in exited, exited[-9000:]
        assert "OBSERVED_PI_FIXTURE" in exited, exited[-9000:]
        send("q"); read_for(1)
        viewer.wait(timeout=8)
        final = output.decode("utf8", "replace")
        assert "Failed to load extension" not in final and "TypeError:" not in final and "ReferenceError:" not in final, final[-9000:]
        assert all(r["toolCount"] == 0 and r["turns"] == 0 for r in snapshots())
        assert all(r.get("endedAt") for r in snapshots())
        print("PASS: two real Pi processes, separate offline dashboard, per-session identity, live heartbeat, read-only details, resize, exits and clean shutdown; no model calls")
    finally:
        for child in (viewer, observed):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        os.close(master)
