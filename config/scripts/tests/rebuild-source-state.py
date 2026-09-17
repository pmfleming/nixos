"""Real-Git tests for the identity passed from snapshot capture to approval."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
scripts = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("state", scripts / "rebuild-source-state.py")
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / "flake.nix").write_text("before\n")
        (self.root / "flake.lock").write_text('{"remote": "before"}\n')
        self.commit()
        self.manifest = self.base / "manifest.json"

    def git(self, *args):
        return state.git(self.root, *args)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "test")

    def capture(self):
        frozen = self.base / "frozen"
        shutil.copytree(self.root, frozen, ignore=shutil.ignore_patterns(".git"))
        self.manifest.write_text(json.dumps(state.capture(self.root, frozen, state.revision(self.root))))
        return frozen

    def test_unchanged_and_lock_only_dirty_configuration(self):
        (self.root / "flake.lock").write_text('{"remote": "new"}\n')
        frozen = self.capture()
        # Disposable resolution must not overwrite approval's input-lock identity.
        (frozen / "flake.lock").write_text("resolved local graph\n")
        result = state.verify(self.root, self.manifest)
        self.assertEqual(result["lockHash"], state.file_identity(self.root / "flake.lock")[2])

    def test_commit_during_build(self):
        self.capture()
        (self.root / "flake.nix").write_text("later\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "sources changed during build"):
            state.verify(self.root, self.manifest)

    def test_lock_change_during_build(self):
        self.capture()
        (self.root / "flake.lock").write_text("later\n")
        with self.assertRaisesRegex(ValueError, "sources changed during build"):
            state.verify(self.root, self.manifest)

    def test_dirty_configuration_never_approved_by_later_commit(self):
        (self.root / "flake.nix").write_text("dirty\n")
        self.capture()
        self.commit()
        with self.assertRaisesRegex(ValueError, "dirty or changed during capture"):
            state.verify(self.root, self.manifest)

    def test_dirty_sibling_does_not_gate_approval(self):
        self.capture()
        (self.base / "sibling").mkdir()
        (self.base / "sibling/source").write_text("dirty\n")
        state.verify(self.root, self.manifest)

    def test_untracked_configuration_rejected(self):
        self.capture()
        (self.root / "new.nix").write_text("new\n")
        with self.assertRaisesRegex(ValueError, "sources changed during build"):
            state.verify(self.root, self.manifest)

    def test_preflight_aggregates_repositories_and_respects_follows(self):
        sibling = self.base / "sibling"
        sibling.mkdir()
        subprocess.run(["git", "init", "-q", str(sibling)], check=True)
        (sibling / "flake.nix").write_text("{}\n")
        (sibling / ".gitignore").write_text("ignored/\n")
        state.git(sibling, "add", ".")
        (sibling / "ignored").mkdir()
        (sibling / "ignored/output").write_text("ignored\n")
        (sibling / "image.png").write_text("untracked\n")
        (self.root / "forgotten.nix").write_text("untracked\n")
        missing = self.base / "missing"
        definitions = {
            self.root: {"sibling": {"url": str(sibling)}, "again": {"url": str(sibling)},
                        "followed": {"follows": "sibling", "url": str(missing)}},
            sibling: {},
        }
        inspected = []

        class Helper:
            @staticmethod
            def read_inputs(root):
                inspected.append(root)
                return definitions[root]

            @staticmethod
            def local_path(spec, root):
                return Path(spec["url"])

            @staticmethod
            def merge(left, right):
                return dict(left, **right)

        with self.assertRaises(ValueError) as failure:
            state.preflight(Helper, self.root)
        message = str(failure.exception)
        self.assertIn("forgotten.nix", message)
        self.assertIn("image.png", message)
        self.assertNotIn("ignored/output", message)
        self.assertNotIn(str(missing), message)
        self.assertEqual(inspected, [self.root, sibling])
        self.assertEqual(state.git(sibling, "ls-files", "--others", "--exclude-standard").decode(), "image.png\n")

    def test_prepare_captures_before_disposable_lock_rewrite(self):
        class Helper:
            remote = "before"

            @staticmethod
            def read_inputs(root):
                return {}

            @staticmethod
            def prune_lock(lock, names):
                return {"remote": lock["remote"]}

            def snapshot(inner, source, target):
                shutil.copytree(source, target, ignore=shutil.ignore_patterns(".git"))

            def prepare(inner, root, destination):
                inner.snapshot(root, destination)
                (destination / "flake.lock").write_text(json.dumps({"remote": inner.remote, "local": "disposable"}))
                return {"flake": "path:" + str(destination)}

        helper = Helper()
        state.prepare(helper, self.root, self.base / "frozen", self.manifest)
        state.verify(self.root, self.manifest)
        self.assertEqual(json.loads(self.manifest.read_text())["lock"], state.file_identity(self.root / "flake.lock"))
        helper.remote = "changed"
        state.prepare(helper, self.root, self.base / "changed", self.manifest)
        with self.assertRaisesRegex(ValueError, "remote pins changed during snapshot resolution"):
            state.verify(self.root, self.manifest)


if __name__ == "__main__":
    unittest.main()
