import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("canonical_dbus", Path(__file__).parents[1] / "canonical-dbus.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CanonicalDbusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "base"
        self.source.mkdir()
        self.profile = self.root / "profile"
        self.output = self.root / "out"

    def service(self, directory, name="org.example.Test", command="/bin/true", filename=None):
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (filename or name + ".service")
        path.write_text(f"[D-BUS Service]\nName={name}\nExec={command}\n")
        return path

    def configs(self, directories):
        for scope in ("system", "session"):
            root = ET.Element("busconfig")
            ET.SubElement(root, "type").text = scope
            if scope == "session":
                ET.SubElement(root, "standard_session_servicedirs")
            ET.SubElement(root, "includedir").text = "/preserved/policy"
            policy = ET.SubElement(root, "policy", {"context": "default"})
            ET.SubElement(policy, "deny", {"own": "*"})
            for directory in directories:
                ET.SubElement(root, "servicedir").text = str(directory)
            ET.ElementTree(root).write(self.source / f"{scope}.conf")

    def run_build(self):
        module.canonicalize(self.source, self.output, self.profile)

    def test_identical_symlinks_and_repeated_directories_collapse(self):
        directory = self.root / "package"
        original = self.service(directory)
        alias = self.root / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        self.configs([directory, alias, directory])
        self.run_build()
        for scope in ("system", "session"):
            files = list((self.output / f"{scope}-services").iterdir())
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].resolve(), original)
            before = ET.parse(self.source / f"{scope}.conf").getroot()
            after = ET.parse(self.output / f"{scope}.conf").getroot()
            preserved = lambda root: [ET.tostring(e) for e in root if e.tag != "servicedir"]
            self.assertEqual(preserved(before), preserved(after))

    def test_session_uses_profile_without_duplicate_and_keeps_supplement(self):
        directory = self.root / "package"
        self.service(directory)
        self.service(directory, "org.example.Extra")
        self.service(self.profile / "share/dbus-1/services")
        self.configs([directory])
        self.run_build()
        self.assertEqual(len(list((self.output / "system-services").iterdir())), 2)
        self.assertEqual([p.name for p in (self.output / "session-services").iterdir()], ["org.example.Extra.service"])
        self.assertIsNotNone(ET.parse(self.output / "session.conf").getroot().find("standard_session_servicedirs"))

    def test_conflicting_packages_fail_closed(self):
        self.service(self.root / "a")
        self.service(self.root / "b", command="/other")
        self.configs([self.root / "a", self.root / "b"])
        with self.assertRaisesRegex(ValueError, "conflicting activation"):
            self.run_build()

    def test_conflicting_profile_fails_closed(self):
        self.service(self.root / "a")
        self.service(self.profile / "share/dbus-1/services", command="/other")
        self.configs([self.root / "a"])
        with self.assertRaisesRegex(ValueError, "profile conflicts"):
            self.run_build()

    def test_filename_is_bus_name_and_invalid_names_rejected(self):
        self.service(self.root / "a", filename="legacy.service")
        self.configs([self.root / "a"])
        self.run_build()
        self.assertTrue((self.output / "system-services/org.example.Test.service").exists())
        self.service(self.root / "invalid", name="../../escape", filename="bad.service")
        with self.assertRaisesRegex(ValueError, "invalid bus name"):
            module.catalog([self.root / "invalid"])

    def test_missing_directories_are_optional(self):
        self.configs([self.root / "missing"])
        self.run_build()
        self.assertEqual(list((self.output / "system-services").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
