#!/usr/bin/env sh
set -eu

exec rofi \
  -show nm-wifi \
  -modi "nm-wifi:nm-wifi-rofi rofi" \
  -kb-custom-1 "Alt+r"
