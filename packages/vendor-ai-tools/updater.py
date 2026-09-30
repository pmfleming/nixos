#!/usr/bin/env python3
"""Vendor-only release discovery and independently rooted, checked Nix profiles.

No host flake evaluation, git inspection, npm installation outside a Nix sandbox,
or vendor code execution in the privileged updater process.
"""

import argparse
import base64
import concurrent.futures
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

TOOLS = ("claude", "codex", "pi", "t3")
REPOS = {"codex": "openai/codex", "pi": "earendil-works/pi", "t3": "pingdotgg/t3code"}
CLAUDE = "https://downloads.claude.ai/claude-code-releases"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def now():
    return int(time.time())


def load(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_link(path, target):
    temporary = path.with_name(path.name + ".new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    os.replace(temporary, path)
    sync_dir(path.parent)


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True


def download(url, limit=2_000_000):
    if not url.startswith("https://"):
        raise ValueError("Release metadata must use HTTPS")
    request = urllib.request.Request(
        url, headers={"User-Agent": "nixos-vendor-ai-tools/1"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if not response.url.startswith("https://"):
            raise ValueError("Insecure release metadata redirect")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Release metadata exceeds size limit")
    return data


def version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError(f"Not a stable three-component release version: {value!r}")
    return value


def version_key(value):
    return tuple(map(int, version(value).split(".")))


def sha256(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", value):
        raise ValueError("Missing or invalid vendor SHA-256 checksum")
    return "sha256-" + base64.b64encode(bytes.fromhex(value)).decode()


def verify(data, asset):
    actual = "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()
    if actual != asset["hash"]:
        raise ValueError(f"Vendor checksum mismatch for {asset['url']}")
    return data


def discover(tool):
    if tool == "claude":
        ver = version(download(f"{CLAUDE}/latest").decode().strip())
        manifest = json.loads(download(f"{CLAUDE}/{ver}/manifest.json"))
        if manifest["version"] != ver:
            raise ValueError("Claude manifest version mismatch")
        return {
            "tool": tool,
            "version": ver,
            "source": f"{CLAUDE}/{ver}/manifest.json",
            "assets": {
                "binary": {
                    "url": f"{CLAUDE}/{ver}/linux-x64/claude",
                    "hash": sha256(manifest["platforms"]["linux-x64"]["checksum"]),
                }
            },
        }

    repo = REPOS[tool]
    release = json.loads(
        download(f"https://api.github.com/repos/{repo}/releases/latest")
    )
    if release["draft"] or release["prerelease"]:
        raise ValueError("Refusing a draft or prerelease")
    tag = release["tag_name"]
    prefix = "rust-v" if tool == "codex" else "v"
    if not tag.startswith(prefix):
        raise ValueError(f"Unexpected release tag: {tag}")
    ver = version(tag[len(prefix) :])
    assets = {a["name"]: a for a in release["assets"]}

    def asset(name):
        entry = assets[name]
        expected = f"https://github.com/{repo}/releases/download/{tag}/{name}"
        if entry["browser_download_url"] != expected:
            raise ValueError("Unexpected vendor asset URL")
        digest = entry.get("digest") or ""
        if not digest.startswith("sha256:"):
            raise ValueError(f"Vendor did not publish a SHA-256 digest for {name}")
        return {"url": expected, "hash": sha256(digest.removeprefix("sha256:"))}

    names = {
        "codex": {"archive": "codex-package-x86_64-unknown-linux-musl.tar.gz"},
        "pi": {
            "package": "pi-coding-agent-install-package.json",
            "lock": "pi-coding-agent-install-package-lock.json",
        },
        "t3": {
            "archive": f"t3-{ver}-linux-x64.tar.gz",
            "desktop": f"T3-Code-{ver}-amd64.deb",
        },
    }[tool]
    selected = {key: asset(name) for key, name in names.items()}
    # Cross-check separately published checksum manifests where provided.
    sums_name = "codex-package_SHA256SUMS" if tool == "codex" else "SHA256SUMS"
    sums_asset = asset(sums_name)
    sums = verify(download(sums_asset["url"]), sums_asset).decode()
    checksums = {}
    for line in sums.splitlines():
        digest, filename = line.split(maxsplit=1)
        checksums[filename.lstrip("*")] = sha256(digest)
    for key, name in names.items():
        if name in checksums and selected[key]["hash"] != checksums[name]:
            raise ValueError(f"Conflicting vendor checksums for {name}")
    npm_integrities = {}
    if tool == "pi":
        # Validate the official npm lock before Nix interprets it. Every dependency
        # must be immutable registry content, never a git/file URL or install script.
        package = json.loads(
            verify(download(selected["package"]["url"]), selected["package"])
        )
        lock = json.loads(verify(download(selected["lock"]["url"]), selected["lock"]))
        if package["dependencies"] != {"@earendil-works/pi-coding-agent": ver}:
            raise ValueError("Pi installer package does not select the release")
        if (
            lock["packages"]["node_modules/@earendil-works/pi-coding-agent"]["version"]
            != ver
        ):
            raise ValueError("Pi installer lock version mismatch")
        for name, entry in lock["packages"].items():
            if not name:
                continue
            if not entry.get("resolved", "").startswith(
                "https://registry.npmjs.org/"
            ) or entry.get("link"):
                raise ValueError(f"Non-registry Pi dependency: {name}")
            integrity = entry.get("integrity")
            if not integrity:
                # Upstream's release lock omits integrity for its own freshly
                # published workspace packages. Resolve that exact version, never latest.
                package_name = name.rsplit("node_modules/", 1)[-1]
                metadata = json.loads(
                    download(
                        f"https://registry.npmjs.org/{package_name}/{version(entry['version'])}"
                    )
                )
                if metadata["dist"]["tarball"] != entry["resolved"]:
                    raise ValueError(f"Registry URL disagrees with Pi lock: {name}")
                integrity = metadata["dist"]["integrity"]
                npm_integrities[name] = integrity
            if not re.fullmatch(r"sha(256|512)-[A-Za-z0-9+/]+=*", integrity):
                raise ValueError(f"Unpinned Pi dependency: {name}")
    result = {
        "tool": tool,
        "version": ver,
        "source": release["html_url"],
        "published_at": release["published_at"],
        "assets": selected,
    }
    if tool == "pi":
        result["npm_integrities"] = npm_integrities
    return result


def run(command, timeout=2700):
    """Bound commands and their descendants; capture actionable build diagnostics."""
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=errors, start_new_session=True
        )
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            process.stdout.close()
            raise
        errors.seek(0, os.SEEK_END)
        size = errors.tell()
        errors.seek(max(0, size - 8000))
        detail = errors.read().decode(errors="replace")
        if process.returncode:
            raise RuntimeError(f"{command[0]} exited {process.returncode}:\n{detail}")
        return stdout.decode().strip()


class Updater:
    def __init__(self, config):
        self.config = config
        self.root = Path(config["state"])

    def directory(self, tool):
        return self.root / tool

    def installed(self, tool):
        return load(self.directory(tool) / "current/share/vendor-ai/release.json")

    def bootstrap(self, tool):
        candidates = []
        if self.config.get("legacy"):
            candidates.append(Path(self.config["legacy"]) / "bin" / tool)
        if tool in self.config.get("bootstrap", {}):
            candidates.append(Path(self.config["bootstrap"][tool]))
        return next((path for path in candidates if path.is_file()), None)

    def status(self, tool):
        directory = self.directory(tool)
        state = load(
            directory / "status.json", {"tool": tool, "phase": "never-checked"}
        )
        installed = self.installed(tool)
        bootstrap = self.bootstrap(tool) if not installed else None
        fallback_version = (
            re.search(r"-([0-9]+\.[0-9]+\.[0-9]+)/", str(bootstrap.resolve()))
            if bootstrap
            else None
        )
        state["installed_version"] = (
            installed["version"]
            if installed
            else (fallback_version[1] if fallback_version else None)
        )
        state["origin"] = "vendor" if installed else "bootstrap"
        state["profile"] = (
            str((directory / "current").resolve())
            if installed
            else (str(bootstrap.resolve()) if bootstrap else None)
        )
        # Link mtime is an activation timestamp even if power failed before status was saved.
        state["last_activation"] = (
            int((directory / "current").lstat().st_mtime)
            if installed
            else state.get("last_activation")
        )
        state["hold"] = load(directory / "hold.json")
        age = now() - state.get("last_successful_check", 0)
        state["stale"] = age < 0 or age >= 4 * 3600
        return state

    def report(self, tool):
        try:
            return self.status(tool)
        except Exception as error:
            return {
                "tool": tool,
                "phase": "failed",
                "installed_version": None,
                "stale": True,
                "error": f"Cannot read {tool} state: {error}",
            }

    def fingerprint(self, tool, release):
        inputs = {k: self.config[k] for k in ("nixpkgs", "recipe")}
        if tool == "pi":
            inputs["extensions"] = self.config["extensions"]
        return hashlib.sha256(
            json.dumps([inputs, release], sort_keys=True).encode()
        ).hexdigest()

    def build(self, tool, release, fingerprint):
        generations = self.directory(tool) / "generations"
        generations.mkdir(parents=True, exist_ok=True)
        generation = generations / f"{now()}-{uuid.uuid4().hex}"
        generation.mkdir()
        atomic_json(generation / "release.json", release)
        atomic_json(generation / "build.json", {"fingerprint": fingerprint})
        try:
            # The stable per-generation out-link is an indirect GC root. Never move it.
            run(
                [
                    self.config["nix_build"],
                    self.config["recipe"],
                    "--argstr",
                    "nixpkgs",
                    self.config["nixpkgs"],
                    "--argstr",
                    "manifestFile",
                    str(generation / "release.json"),
                    "--argstr",
                    "piExtensions",
                    self.config["extensions"],
                    "--out-link",
                    str(generation / "profile"),
                    "--option",
                    "allow-import-from-derivation",
                    "true",
                ]
            )
            if load(generation / "profile/share/vendor-ai/release.json") != release:
                raise ValueError("Built profile does not match the requested release")
            return generation / "profile"
        except BaseException:
            shutil.rmtree(generation)
            raise

    def activate(self, tool, profile):
        directory = self.directory(tool)
        current = directory / "current"
        if current.is_symlink():
            atomic_link(directory / "previous", os.readlink(current))
        atomic_link(current, profile)
        self.prune(tool)

    def prune(self, tool):
        directory = self.directory(tool)
        protected = {
            os.readlink(p)
            for p in (directory / "current", directory / "previous")
            if p.is_symlink()
        }
        generations = directory / "generations"
        if not generations.exists():
            return
        for generation in generations.iterdir():
            if str(generation / "profile") not in protected:
                shutil.rmtree(generation)

    def update(self, tool, check_only=False):
        directory = self.directory(tool)
        with locked(directory / "update.lock") as acquired:
            if not acquired:
                return (
                    False  # Do not overwrite a live owner's status or report success.
                )
            self.prune(tool)  # Remove abandoned candidates left by interrupted builds.
            state = self.status(tool)
            state.update(phase="checking", last_attempt=now(), error=None)
            atomic_json(directory / "status.json", state)
            try:
                release = discover(tool)
                state.update(
                    latest_version=release["version"],
                    latest_release=release,
                    last_successful_check=now(),
                )
                atomic_json(directory / "status.json", state)
                installed = self.installed(tool)
                fingerprint = self.fingerprint(tool, release)
                held = load(directory / "hold.json")
                if held:
                    state.update(
                        phase="held",
                        error="Updates paused after rollback; use ai-tools resume "
                        + tool,
                    )
                elif state["installed_version"] and version_key(
                    release["version"]
                ) < version_key(state["installed_version"]):
                    raise ValueError(
                        "Vendor latest moved backwards; refusing an automatic downgrade"
                    )
                elif check_only:
                    state["phase"] = "current" if installed == release else "available"
                else:
                    current = directory / "current"
                    previous_build = (
                        load(Path(os.readlink(current)).parent / "build.json", {})
                        if current.is_symlink()
                        else {}
                    )
                    if (
                        installed == release
                        and previous_build.get("fingerprint") == fingerprint
                    ):
                        state["phase"] = "current"
                    else:
                        state["phase"] = "building"
                        atomic_json(directory / "status.json", state)
                        profile = self.build(tool, release, fingerprint)
                        self.activate(tool, profile)
                        state.update(phase="activated", last_activation=now())
                state["error"] = state.get("error") if held else None
            except Exception as error:
                state.update(phase="failed", error=str(error)[-8000:])
                print(f"{tool}: {error}", file=sys.stderr, flush=True)
            finally:
                state["finished_at"] = now()
                atomic_json(directory / "status.json", state)
            return state["phase"] not in ("failed", "held")

    def rollback(self, tool):
        directory = self.directory(tool)
        with locked(directory / "update.lock") as acquired:
            if not acquired:
                raise RuntimeError(f"{tool} update is busy")
            previous = directory / "previous"
            current = directory / "current"
            target = (
                os.readlink(previous)
                if previous.is_symlink() and previous.exists()
                else None
            )
            if target is None and (
                not current.is_symlink() or not self.bootstrap(tool)
            ):
                raise ValueError(f"No previous {tool} profile or bootstrap fallback")
            # Hold first: interruption must not allow the next timer to undo rollback.
            atomic_json(
                directory / "hold.json", {"since": now(), "reason": "manual rollback"}
            )
            if target is None:
                # First vendor installation can roll back to the retained bootstrap.
                atomic_link(previous, os.readlink(current))
                current.unlink()
                sync_dir(directory)
            else:
                self.activate(tool, target)
            state = self.status(tool)
            state.update(
                phase="held",
                error="Rolled back; automatic updates paused until resume",
                last_activation=now(),
            )
            atomic_json(directory / "status.json", state)

    def resume(self, tool):
        directory = self.directory(tool)
        with locked(directory / "update.lock") as acquired:
            if not acquired:
                raise RuntimeError(f"{tool} update is busy")
            (directory / "hold.json").unlink(missing_ok=True)
            sync_dir(directory)

    def job(self, operation, phase, status="running", error=None, started=None):
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        start = Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19]
        stamp = now()
        record = {
            "schema_version": 1,
            "id": f"{boot}-{os.getpid()}-{start}",
            "operation": operation,
            "status": status,
            "phase": phase,
            "started_at": started or stamp,
            "updated_at": stamp,
            "finished_at": stamp if status != "running" else None,
            "exit_code": (1 if status == "failed" else 0)
            if status != "running"
            else None,
            "pid": os.getpid(),
            "boot_id": boot,
            "process_start": start,
            "error": error,
        }
        name = "ai-tools-stale" if operation == "ai-stale" else "ai-tools"
        atomic_json(Path(self.config["jobs"]) / f"{name}.json", record)

    def notify(self, errors):
        marker = self.root / "last-notification.json"
        last = load(marker, {})
        if now() - last.get("at", 0) < 6 * 3600:
            return
        command = self.config.get("notify_command")
        if command:
            try:
                run(
                    command + ["AI tool updates need attention", errors[:1500]],
                    timeout=15,
                )
            except Exception as error:
                print(f"Desktop notification unavailable: {error}", file=sys.stderr)
                return
            atomic_json(marker, {"at": now()})

    def batch(self, tools, check_only=False, stale=False):
        # Preserve the existing bar-daemon reader contract and serialize with the
        # retired worker during migration. Per-tool profiles/locks remain separate.
        with locked(Path(self.config["jobs"]) / "ai-tools.lock") as acquired:
            if not acquired:
                print("Another AI update operation is running", file=sys.stderr)
                return 75
            started = now()
            operation = "ai-stale" if stale else "ai-update"
            self.job(operation, "checking", started=started)
            failures = {}
            if not stale:

                def attempt(tool):
                    try:
                        return self.update(tool, check_only)
                    except Exception as error:
                        # Even corrupt state or failed lock/setup IO belongs to
                        # one tool, not to the entire batch.
                        print(f"{tool}: {error}", file=sys.stderr, flush=True)
                        failures[tool] = str(error)
                        return False

                with concurrent.futures.ThreadPoolExecutor(
                    max_workers=len(tools)
                ) as pool:
                    results = list(pool.map(attempt, tools))
            else:
                results = [True]
            states = [self.report(tool) for tool in TOOLS]
            for state in states:
                if state["tool"] in failures:
                    state.update(phase="failed", error=failures[state["tool"]])
            problems = [
                f"{s['tool']}: {s.get('error') or 'no successful release check in four hours'}"
                for s in states
                if s["stale"] or s["phase"] in ("failed", "held")
            ]
            if not all(results) and not problems:
                problems.append(
                    "A tool is busy; retry after its current operation finishes"
                )
            error = "; ".join(problems)[:6000]
            phases = {s["phase"] for s in states}
            phase = (
                "stale"
                if stale and problems
                else "blocked"
                if problems
                else (
                    "available"
                    if "available" in phases
                    else "activated"
                    if "activated" in phases
                    else "current"
                )
            )
            self.job(
                operation,
                phase,
                "failed" if problems and not stale else "completed",
                error or None,
                started,
            )
            if problems:
                self.notify(error)
            # An unrelated tool's failure stays visible but cannot fail a targeted update.
            return int(not all(results)) if not stale else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    for op in ("update", "check", "rollback", "resume"):
        command = sub.add_parser(op)
        command.add_argument(
            "tool",
            choices=(*TOOLS, "all") if op in ("update", "check") else TOOLS,
            **({"nargs": "?", "default": "all"} if op in ("update", "check") else {}),
        )
    sub.add_parser("stale")
    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true")
    args = parser.parse_args()
    updater = Updater(load(args.config))
    if args.command == "status":
        states = [updater.report(tool) for tool in TOOLS]
        if args.json:
            print(json.dumps(states, indent=2))
        else:
            for state in states:

                def stamp(key):
                    value = state.get(key)
                    return (
                        time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(value))
                        if value
                        else "never"
                    )

                print(
                    f"{state['tool']:7} installed={state['installed_version'] or 'bootstrap fallback'} "
                    f"latest={state.get('latest_version', 'unknown')} phase={state['phase']}"
                    f"{' (stale check)' if state['stale'] else ''}\n"
                    f"        checked={stamp('last_successful_check')} activated={stamp('last_activation')}"
                )
                if state.get("error"):
                    print("        " + state["error"])
        return 0
    if args.command in ("rollback", "resume"):
        getattr(updater, args.command)(args.tool)
        return 0
    tools = TOOLS if getattr(args, "tool", "all") == "all" else (args.tool,)
    return updater.batch(
        tools, check_only=args.command == "check", stale=args.command == "stale"
    )


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"ai-tools: {error}", file=sys.stderr)
        sys.exit(1)
