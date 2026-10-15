"""Build canonical activation directories; never rewrite D-Bus authorization policy.

System activation has one directory. Session activation retains standard XDG
search/override order; explicit package services already in the system profile
are omitted from the supplemental directory. Different definitions for the same
name fail the build rather than silently changing activation precedence.
"""

import configparser
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


BUS_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)+\Z")


def catalog(directories):
    result = {}
    for directory in directories:
        for path in sorted(Path(directory).glob("*.service")):
            text = path.read_text()
            parser = configparser.ConfigParser(interpolation=None, strict=True)
            parser.optionxform = str
            parser.read_string(text)
            name = parser["D-BUS Service"]["Name"]
            if not BUS_NAME.fullmatch(name):
                raise ValueError(f"invalid bus name {name!r}: {path}")
            if name in result and result[name].read_text() != text:
                raise ValueError(f"conflicting activation for {name}: {result[name]} and {path}")
            result.setdefault(name, path.resolve())
    return result


def canonicalize(source, destination, system_profile):
    source, destination, system_profile = map(Path, (source, destination, system_profile))
    destination.mkdir(parents=True, exist_ok=True)
    profile = catalog([system_profile / "share/dbus-1/services"])
    manifest = {}
    for scope in ("system", "session"):
        tree = ET.parse(source / f"{scope}.conf")
        root = tree.getroot()
        service_elements = root.findall("servicedir")
        services = catalog([entry.text for entry in service_elements])
        before = sorted(services)
        if scope == "session":
            if root.find("standard_session_servicedirs") is None:
                raise ValueError("session configuration must preserve standard XDG discovery")
            for name in services.keys() & profile.keys():
                if services[name].read_bytes() != profile[name].read_bytes():
                    raise ValueError(f"system profile conflicts with explicit activation: {name}")
            services = {name: path for name, path in services.items() if name not in profile}
        directory = destination / f"{scope}-services"
        directory.mkdir()
        for name, path in sorted(services.items()):
            (directory / f"{name}.service").symlink_to(path)
        for entry in service_elements:
            root.remove(entry)
        ET.SubElement(root, "servicedir").text = str(directory)
        # All policy, includes, limits, authentication and XDG directives are
        # retained in their original order. Only activation search paths change.
        tree.write(destination / f"{scope}.conf", encoding="utf-8", xml_declaration=True)
        manifest[scope] = {"before": before, "explicit": sorted(services)}
        if scope == "session":
            manifest[scope]["system_profile"] = sorted(profile)
    (destination / "activation-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    canonicalize(*sys.argv[1:])
