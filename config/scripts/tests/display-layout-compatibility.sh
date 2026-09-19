set -euo pipefail
root=${1:?NixOS source root required}
# Activated Home Manager generations can still link to this source module.
# Removing its source breaks the live session before any new activation.
test -s "$root/config/hypr/monitors.lua"
grep -Fq 'require("monitors")' "$root/config/hypr/hyprland.lua"
grep -Fq '"hypr/monitors.lua" = writableConfig "hypr/monitors.lua";' "$root/home.nix"
printf 'Display module compatibility passed\n'
