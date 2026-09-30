import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "updater", Path(__file__).parents[1] / "updater.py"
)
u = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(u)


def release(tool, version="1.2.3"):
    return {
        "tool": tool,
        "version": version,
        "assets": {},
        "source": "https://example.invalid/release",
    }


class Profiles(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {
            "state": str(self.root / "state"),
            "jobs": str(self.root / "jobs"),
            "nixpkgs": "/immutable/nixpkgs",
            "recipe": "/immutable/package.nix",
            "extensions": "/immutable/pi",
            "nix_build": "/immutable/nix-build",
        }
        self.worker = u.Updater(self.config)
        self.counter = 0

    def build(self, tool, rel, fingerprint):
        self.counter += 1
        directory = self.worker.directory(tool) / "generations" / str(self.counter)
        profile = directory / "profile"
        u.atomic_json(profile / "share/vendor-ai/release.json", rel)
        u.atomic_json(directory / "build.json", {"fingerprint": fingerprint})
        binary = profile / "bin" / tool
        binary.parent.mkdir()
        binary.write_text(f"#!/bin/sh\nprintf '%s\\n' '{rel['version']}'\n")
        binary.chmod(0o755)
        return profile

    def update(self, tool, ver="1.2.3"):
        with (
            patch.object(u, "discover", return_value=release(tool, ver)),
            patch.object(self.worker, "build", self.build),
        ):
            return self.worker.update(tool)

    def test_atomic_launch_and_failed_build_preserves_current(self):
        self.assertTrue(self.update("claude"))
        command = self.worker.directory("claude") / "current/bin/claude"
        self.assertEqual(subprocess.check_output([command]).strip(), b"1.2.3")
        with (
            patch.object(u, "discover", return_value=release("claude", "1.2.4")),
            patch.object(
                self.worker, "build", side_effect=RuntimeError("checksum mismatch")
            ),
        ):
            self.assertFalse(self.worker.update("claude"))
        self.assertEqual(subprocess.check_output([command]).strip(), b"1.2.3")
        state = self.worker.status("claude")
        self.assertEqual(state["installed_version"], "1.2.3")
        self.assertEqual(state["latest_version"], "1.2.4")
        self.assertIn("checksum mismatch", state["error"])
        self.assertTrue(state["last_successful_check"])
        self.assertTrue(self.update("claude", "1.2.4"))
        self.assertEqual(subprocess.check_output([command]).strip(), b"1.2.4")

    def test_first_vendor_install_can_rollback_to_bootstrap(self):
        fallback = self.root / "store" / "hash-claude-code-1.0.0/bin/claude"
        fallback.parent.mkdir(parents=True)
        fallback.write_text("bootstrap")
        self.config["bootstrap"] = {"claude": str(fallback)}
        self.assertEqual(self.worker.status("claude")["installed_version"], "1.0.0")
        self.update("claude")
        self.worker.rollback("claude")
        self.assertIsNone(self.worker.installed("claude"))
        self.assertEqual(self.worker.status("claude")["installed_version"], "1.0.0")
        self.assertFalse(self.update("claude"))
        self.worker.resume("claude")
        self.assertTrue(self.update("claude"))

    def test_targeted_success_is_not_failed_by_an_unrelated_tool(self):
        with (
            patch.object(u, "discover", side_effect=release),
            patch.object(self.worker, "build", self.build),
        ):
            self.assertEqual(self.worker.batch(("claude",)), 0)
        self.assertEqual(self.worker.installed("claude")["version"], "1.2.3")

    def test_abandoned_candidate_root_is_cleaned_on_next_attempt(self):
        self.update("claude")
        orphan = self.worker.directory("claude") / "generations/orphan"
        orphan.mkdir()
        (orphan / "profile").symlink_to("/missing")
        self.update("claude")
        self.assertFalse(orphan.exists())
        self.assertEqual(self.worker.installed("claude")["version"], "1.2.3")

    def test_rollback_remains_held_until_resume(self):
        self.update("codex")
        self.update("codex", "1.2.4")
        self.worker.rollback("codex")
        self.assertEqual(self.worker.installed("codex")["version"], "1.2.3")
        self.assertFalse(self.update("codex", "1.2.4"))
        self.assertEqual(self.worker.installed("codex")["version"], "1.2.3")
        self.worker.resume("codex")
        self.assertTrue(self.update("codex", "1.2.4"))
        self.assertEqual(self.worker.installed("codex")["version"], "1.2.4")
        self.assertEqual(
            len(list((self.worker.directory("codex") / "generations").iterdir())), 2
        )

    def test_pi_failure_cannot_block_other_tools(self):
        def build(tool, rel, fingerprint):
            if tool == "pi":
                raise RuntimeError("Pi extension incompatibility")
            return self.build(tool, rel, fingerprint)

        with (
            patch.object(u, "discover", side_effect=release),
            patch.object(self.worker, "build", side_effect=build),
        ):
            self.assertEqual(self.worker.batch(u.TOOLS), 1)
        for tool in ("claude", "codex", "t3"):
            self.assertEqual(self.worker.installed(tool)["version"], "1.2.3")
        self.assertIsNone(self.worker.installed("pi"))
        job = u.load(self.root / "jobs/ai-tools.json")
        self.assertEqual(job["status"], "failed")
        self.assertIn("Pi extension incompatibility", job["error"])
        self.assertEqual(job["schema_version"], 1)

    def test_corrupt_tool_state_does_not_abort_other_updates(self):
        directory = self.worker.directory("pi")
        directory.mkdir(parents=True)
        (directory / "status.json").write_text("not JSON")
        with (
            patch.object(u, "discover", side_effect=release),
            patch.object(self.worker, "build", self.build),
        ):
            self.assertEqual(self.worker.batch(u.TOOLS), 1)
        for tool in ("claude", "codex", "t3"):
            self.assertEqual(self.worker.installed(tool)["version"], "1.2.3")
        self.assertIn("Cannot read pi state", self.worker.report("pi")["error"])
        self.assertEqual(u.load(self.root / "jobs/ai-tools.json")["status"], "failed")

    def test_unrelated_untracked_work_has_no_effect(self):
        # Deliberately hostile/untracked host and project content is never inspected.
        (self.root / "flake.nix").write_text('throw "do not evaluate host flake"')
        (self.root / "untracked.ts").write_text("broken work in progress")
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            self.assertTrue(self.update("claude"))
        finally:
            os.chdir(previous)

    def test_latest_check_is_not_activation_and_no_implicit_downgrade(self):
        self.update("t3", "1.2.4")
        installed_at = self.worker.status("t3")["last_activation"]
        with patch.object(u, "discover", return_value=release("t3", "1.2.5")):
            self.assertTrue(self.worker.update("t3", check_only=True))
        state = self.worker.status("t3")
        self.assertEqual(
            (state["installed_version"], state["latest_version"]), ("1.2.4", "1.2.5")
        )
        self.assertEqual(state["phase"], "available")
        self.assertEqual(state["last_activation"], installed_at)
        self.assertFalse(self.update("t3", "1.2.3"))
        self.assertEqual(self.worker.installed("t3")["version"], "1.2.4")

    def test_no_change_skips_build_and_only_pi_depends_on_extensions(self):
        self.update("claude")
        before = self.counter
        self.config["extensions"] = "/new/extensions"
        self.update("claude")
        self.assertEqual(self.counter, before)
        self.update("pi")
        self.config["extensions"] = "/newer/extensions"
        self.update("pi")
        self.assertEqual(self.counter, before + 2)

    def test_network_failure_does_not_refresh_successful_check(self):
        self.update("claude")
        previous = self.worker.status("claude")["last_successful_check"]
        with (
            patch.object(u, "discover", side_effect=OSError("offline")),
            patch.object(u, "now", return_value=previous + 20000),
        ):
            self.assertFalse(self.worker.update("claude"))
            state = self.worker.status("claude")
            self.assertEqual(state["last_successful_check"], previous)
            self.assertTrue(state["stale"])
            self.assertEqual(state["installed_version"], "1.2.3")

    def test_busy_owner_is_not_overwritten(self):
        self.update("pi")
        path = self.worker.directory("pi") / "status.json"
        original = path.read_bytes()
        with u.locked(self.worker.directory("pi") / "update.lock"):
            self.assertFalse(self.worker.update("pi"))
        self.assertEqual(path.read_bytes(), original)

    def test_receipt_and_link_recover_installed_version_without_status(self):
        self.update("pi")
        (self.worker.directory("pi") / "status.json").unlink()
        state = self.worker.status("pi")
        self.assertEqual(state["installed_version"], "1.2.3")
        self.assertIsNotNone(state["last_activation"])
        self.assertTrue(self.update("pi"))

    def test_builder_does_not_evaluate_a_flake_or_move_gc_root(self):
        calls = []

        def nix(command):
            calls.append(command)
            generation = Path(command[command.index("--out-link") + 1]).parent
            rel = u.load(generation / "release.json")
            u.atomic_json(generation / "profile/share/vendor-ai/release.json", rel)

        with patch.object(u, "run", side_effect=nix):
            profile = self.worker.build("claude", release("claude"), "fingerprint")
        self.worker.activate("claude", profile)
        self.assertTrue(profile.exists())
        self.assertEqual(
            os.readlink(self.worker.directory("claude") / "current"), str(profile)
        )
        self.assertEqual(calls[0][1], self.config["recipe"])
        self.assertNotIn("flake", calls[0])
        self.assertNotIn("git", calls[0])

    def test_failed_realisation_removes_candidate_not_active_root(self):
        self.update("codex")
        active = os.readlink(self.worker.directory("codex") / "current")
        with patch.object(u, "run", side_effect=RuntimeError("Nix build failed")):
            with self.assertRaises(RuntimeError):
                self.worker.build("codex", release("codex", "1.2.4"), "new")
        self.assertTrue(Path(active).exists())
        self.assertEqual(
            len(list((self.worker.directory("codex") / "generations").iterdir())), 1
        )


class Discovery(unittest.TestCase):
    def github(self, tool, dependency_url=None):
        repo = u.REPOS[tool]
        tag = "rust-v1.2.3" if tool == "codex" else "v1.2.3"
        base = f"https://github.com/{repo}/releases/download/{tag}/"
        if tool == "pi":
            package_name = "@earendil-works/pi-coding-agent"
            package_url = (
                f"https://registry.npmjs.org/{package_name}/-/pi-coding-agent-1.2.3.tgz"
            )
            payloads = {
                "pi-coding-agent-install-package.json": json.dumps(
                    {"dependencies": {package_name: "1.2.3"}}
                ).encode(),
                "pi-coding-agent-install-package-lock.json": json.dumps(
                    {
                        "packages": {
                            "": {},
                            "node_modules/" + package_name: {
                                "version": "1.2.3",
                                "resolved": dependency_url or package_url,
                            },
                        }
                    }
                ).encode(),
            }
        elif tool == "codex":
            payloads = {"codex-package-x86_64-unknown-linux-musl.tar.gz": b"archive"}
        else:
            payloads = {
                "t3-1.2.3-linux-x64.tar.gz": b"archive",
                "T3-Code-1.2.3-amd64.deb": b"desktop",
            }
        sums = "codex-package_SHA256SUMS" if tool == "codex" else "SHA256SUMS"
        payloads[sums] = "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n"
            for name, data in payloads.items()
        ).encode()
        metadata = {
            "draft": False,
            "prerelease": False,
            "tag_name": tag,
            "html_url": f"https://github.com/{repo}/releases/tag/{tag}",
            "published_at": "2026-09-30T00:00:00Z",
            "assets": [
                {
                    "name": name,
                    "browser_download_url": base + name,
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                }
                for name, data in payloads.items()
            ],
        }
        responses = {base + name: data for name, data in payloads.items()}
        responses[f"https://api.github.com/repos/{repo}/releases/latest"] = json.dumps(
            metadata
        ).encode()
        if tool == "pi":
            responses[f"https://registry.npmjs.org/{package_name}/1.2.3"] = json.dumps(
                {"dist": {"tarball": package_url, "integrity": u.sha256("ab" * 32)}}
            ).encode()
        return responses

    def test_all_github_sources_and_exact_pi_integrity_completion(self):
        for tool in ("codex", "pi", "t3"):
            with self.subTest(tool=tool):
                responses = self.github(tool)
                with patch.object(u, "download", side_effect=responses.__getitem__):
                    result = u.discover(tool)
                self.assertEqual(result["version"], "1.2.3")
                if tool == "pi":
                    self.assertEqual(
                        result["npm_integrities"][
                            "node_modules/@earendil-works/pi-coding-agent"
                        ],
                        u.sha256("ab" * 32),
                    )

    def test_pi_rejects_non_registry_dependency_even_in_hashed_lock(self):
        responses = self.github("pi", "git+https://example.invalid/repo")
        with patch.object(u, "download", side_effect=responses.__getitem__):
            with self.assertRaisesRegex(ValueError, "Non-registry"):
                u.discover("pi")

    def test_corrupt_checksum_manifest_fails_closed(self):
        responses = self.github("codex")
        url = "https://github.com/openai/codex/releases/download/rust-v1.2.3/codex-package_SHA256SUMS"
        responses[url] = b"corrupt"
        with patch.object(u, "download", side_effect=responses.__getitem__):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                u.discover("codex")

    def test_stable_version_validation(self):
        for value in ("1.2.3-beta", "../1.2.3", "latest", "1.2", "1.2.3\n"):
            with self.assertRaises(ValueError):
                u.version(value)
        self.assertEqual(u.version_key("2.10.0"), (2, 10, 0))

    def test_claude_version_and_checksum_required(self):
        manifest = {
            "version": "2.1.285",
            "platforms": {"linux-x64": {"checksum": "ab" * 32}},
        }
        with patch.object(
            u, "download", side_effect=[b"2.1.285", json.dumps(manifest).encode()]
        ):
            result = u.discover("claude")
        self.assertEqual(result["assets"]["binary"]["hash"], u.sha256("ab" * 32))
        manifest["version"] = "2.1.284"
        with patch.object(
            u, "download", side_effect=[b"2.1.285", json.dumps(manifest).encode()]
        ):
            with self.assertRaisesRegex(ValueError, "version mismatch"):
                u.discover("claude")

    def test_github_rejects_prerelease_and_absent_digest(self):
        with patch.object(
            u, "download", return_value=b'{"draft":false,"prerelease":true}'
        ):
            with self.assertRaisesRegex(ValueError, "prerelease"):
                u.discover("codex")
        release = {
            "draft": False,
            "prerelease": False,
            "tag_name": "rust-v1.2.3",
            "assets": [
                {
                    "name": "codex-package-x86_64-unknown-linux-musl.tar.gz",
                    "browser_download_url": "https://github.com/openai/codex/releases/download/rust-v1.2.3/codex-package-x86_64-unknown-linux-musl.tar.gz",
                }
            ],
        }
        with patch.object(u, "download", return_value=json.dumps(release).encode()):
            with self.assertRaisesRegex(ValueError, "digest"):
                u.discover("codex")

    def test_checksum_failure_is_closed(self):
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            u.verify(
                b"corrupt archive",
                {"url": "https://example.invalid", "hash": u.sha256("ab" * 32)},
            )

    def test_subprocess_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            u.run([sys.executable, "-c", "import time; time.sleep(60)"], timeout=0.05)


if __name__ == "__main__":
    unittest.main()
