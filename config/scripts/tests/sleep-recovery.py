"""Check evaluated hooks and the promoted combined kernel/display stack."""

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

    stack = config["defaultStack"]
    assert config["specialisations"] == [], "experimental boot variants must stay retired"
    assert stack["kernel"].startswith("6.18.")
    assert version(stack["kernel"]) >= (6, 18, 53)
    assert version(stack["hyprland"]) >= (0, 56, 2)
    assert version(stack["aquamarine"]) >= (0, 15, 1)
    assert version(stack["mesa"]) >= (26, 2, 3)
    assert stack["mesa"] == stack["mesa32"]
    assert version(stack["portal"]) >= (1, 4, 1)
    print("PASS: explicit DPMS actions, persistent compositor logs, combined stack by default")


if __name__ == "__main__":
    main()
