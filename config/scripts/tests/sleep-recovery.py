"""Check evaluated hooks and the independent HDMI recovery boot configurations."""

import json
import re
import sys


def version(value):
    return tuple(int(part) for part in value.split(".")[:3])


def main():
    with open(sys.argv[1], encoding="utf-8") as source:
        config = json.load(source)

    idle = config["idle"]
    on = "hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'"
    off = "hyprctl dispatch 'hl.dsp.dpms({ action = \"off\" })'"
    assert idle["general"]["after_sleep_cmd"] == on
    assert idle["general"]["before_sleep_cmd"] == "loginctl lock-session"
    blanking = [item for item in idle["listener"] if item["timeout"] == 420]
    assert len(blanking) == 1
    assert blanking[0]["on-timeout"] == off
    assert blanking[0]["on-resume"] == on
    # Exact assertions above also reject bare strings: even "on" toggles.

    lua = config["hyprlandConfig"]
    assert re.search(r"debug\s*=\s*\{[^}]*disable_logs\s*=\s*false", lua)
    assert re.search(r"debug\s*=\s*\{[^}]*enable_stdout_logs\s*=\s*true", lua)

    base = config["baseline"]
    candidates = config["candidates"]
    assert set(candidates) == {"hdmi-kernel", "hdmi-display", "hdmi-combined"}
    kernel = candidates["hdmi-kernel"]
    display = candidates["hdmi-display"]
    combined = candidates["hdmi-combined"]

    assert kernel["kernel"].startswith("6.18.")
    assert version(kernel["kernel"]) >= (6, 18, 53)
    assert display["kernel"] == base["kernel"]
    assert combined["kernel"] == kernel["kernel"]
    for field in ("hyprland", "aquamarine", "portal", "mesa", "mesa32"):
        assert kernel[field] == base[field], f"kernel-only changed {field}"
        assert combined[field] == display[field], f"combined differs in {field}"
    assert version(display["hyprland"]) >= (0, 56, 2)
    assert version(display["aquamarine"]) >= (0, 15, 1)
    assert display["mesa"] == display["mesa32"]
    assert version(display["portal"]) >= (1, 4, 1)
    print("PASS: explicit DPMS actions, persistent compositor logs, isolated HDMI boot candidates")


if __name__ == "__main__":
    main()
