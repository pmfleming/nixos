"""Validate the built host's activation inventory, including a private bus."""
import configparser
from contextlib import contextmanager
import json
import os
import select
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

@contextmanager
def private_process(command, env, errors, stdout=subprocess.DEVNULL):
    """Own private bus cleanup and diagnostics for either implementation."""
    with subprocess.Popen(command, env=env, stdout=stdout, stderr=errors, text=True) as process:
        try:
            yield process
        except (AssertionError, subprocess.SubprocessError):
            errors.seek(0)
            print(errors.read(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
    errors.seek(0)
    stderr = errors.read()
    assert "duplicate" not in stderr.lower(), stderr
    assert "not named after" not in stderr.lower(), stderr


def query_names(env, address, scope, names):
    assert address.startswith("unix:"), address
    result = subprocess.run([
        "dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus.ListActivatableNames",
    ], env=dict(env, DBUS_SESSION_BUS_ADDRESS=address),
        capture_output=True, text=True, timeout=20, check=True)
    for name in names:
        assert f'"{name}"' in result.stdout, (scope, name, result.stdout)


config_dir, system_profile, user_profile = map(Path, sys.argv[1:4])
manifest = json.loads((config_dir / "activation-manifest.json").read_text())
for scope in ("system", "session"):
    root = ET.parse(config_dir / f"{scope}.conf").getroot()
    directories = [Path(e.text) for e in root.findall("servicedir")]
    assert len(directories) == 1
    if scope == "session":
        assert root.find("standard_session_servicedirs") is not None
        directories += [system_profile / "share/dbus-1/services", user_profile / "share/dbus-1/services"]
    names = {}
    for directory in directories:
        for path in directory.glob("*.service"):
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(path)
            name = parser["D-BUS Service"]["Name"]
            assert path.name == name + ".service", (path, name)
            assert name not in names, ("duplicate managed activation", name, names.get(name), path)
            names[name] = path
    assert set(manifest[scope]["before"]) <= names.keys(), "lost activation definition"
    if scope == "system":
        assert "org.laufan.BarBatteryHelper" in names
        assert "org.laufan.BarDaemon" not in names
    else:
        assert "org.laufan.BarDaemon" in names
        assert "org.laufan.UpdateDaemon" in names
        assert "org.freedesktop.Notifications" in names
    # Run a reference bus privately: validate the entire generated configuration
    # and ListActivatableNames, without activating any service or touching live IPC.
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        for entry in list(root):
            if entry.tag in ("user", "pidfile", "listen", "fork"):
                root.remove(entry)
        ET.SubElement(root, "listen").text = f"unix:tmpdir={temp}"
        private = temp / "bus.conf"
        ET.ElementTree(root).write(private)
        env = dict(os.environ, XDG_DATA_DIRS=f"{user_profile}/share:{system_profile}/share",
                   XDG_DATA_HOME=str(temp / "data"), XDG_RUNTIME_DIR=str(temp))
        # --systemd-activation admits systemd-only files (no Exec=) as the
        # production broker does. We only query names, never request activation.
        with (temp / "stderr").open("w+") as errors:
            with private_process([
                "dbus-daemon", "--nofork", "--nopidfile", "--systemd-activation",
                "--print-address=1", "--config-file", str(private),
            ], env, errors, stdout=subprocess.PIPE) as bus:
                assert select.select([bus.stdout], [], [], 10)[0], "private bus startup timed out"
                query_names(env, bus.stdout.readline().strip(), scope, names)
        if "--broker" not in sys.argv:
            # Broker requires journald, absent in an ordinary Nix build sandbox.
            # Run --broker separately on the host against these same store paths.
            print(f"{scope}: {len(names)} unique managed activations; private dbus-daemon check passed")
            continue
        # Exercise the actual production implementation through a private
        # socket-activation wrapper, never the running system/user bus.
        # The launcher also connects to XDG_RUNTIME_DIR/bus for systemd queries.
        socket = temp / "bus"
        with (temp / "broker-stderr").open("w+") as errors:
            with private_process([
                "systemd-socket-activate", "--listen=" + str(socket),
                "--setenv=XDG_DATA_DIRS", "--setenv=XDG_DATA_HOME", "--setenv=XDG_RUNTIME_DIR",
                "dbus-broker-launch", "--scope", "user", "--config-file", str(private),
            ], env, errors) as broker:
                for _ in range(100):
                    if socket.exists() or broker.poll() is not None:
                        break
                    time.sleep(0.05)
                assert socket.exists(), "private broker socket unavailable"
                query_names(env, "unix:path=" + str(socket), scope, names)
    print(f"{scope}: {len(names)} unique managed activations; private dbus-daemon and broker checks passed")
