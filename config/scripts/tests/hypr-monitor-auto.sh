set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HYPR_MONITOR_AUTO_LIB_ONLY=1
# shellcheck source=/dev/null
source "$script_path"

custom_monitors_file="$test_root/monitors.lua"
connected=0
fail_reload=0
calls="$test_root/calls"
: > "$calls"
external_connected() { [ "$connected" = 1 ]; }
hyprctl() {
  printf '%s\n' "$*" >> "$calls"
  [ "$fail_reload" = 0 ]
}

printf '%s\n' 'hl.monitor({ output = "eDP-1", mode = "1920x1200@60.0", scale = 1.25 })' > "$custom_monitors_file"
connected=1
apply_state force
[ "$last_state" = external ]
grep -q 'disabled = true' "$calls"

# Unplugging must reapply the saved layout, not leave the runtime disable rule.
: > "$calls"
connected=0
apply_state force
[ "$last_state" = custom ]
grep -q 'dofile' "$calls"
[ "$(wc -l < "$calls")" -eq 1 ]

# Reapplying a layout generates more monitor events: do not loop on those.
apply_state force
[ "$(wc -l < "$calls")" -eq 1 ]

# A failed restoration must remain retryable on the next event.
last_state=external
fail_reload=1
apply_state force
[ "$last_state" = external ]
fail_reload=0
apply_state force
[ "$last_state" = custom ]

# A disabled internal rule is not a usable saved layout when undocked.
printf '%s\n' 'hl.monitor({ output = "eDP-1", disabled = true })' > "$custom_monitors_file"
: > "$calls"
apply_state force
[ "$last_state" = internal ]
grep -q 'mode = "preferred"' "$calls"
if grep -q 'dofile' "$calls"; then
  printf 'A disabled internal layout was restored instead of the fallback.\n' >&2
  exit 1
fi

# Saved external layouts are restored after reconnecting as well.
printf '%s\n' 'hl.monitor({ output = "DP-1", mode = "preferred" })' >> "$custom_monitors_file"
connected=1
: > "$calls"
apply_state force
[ "$last_state" = custom ]
grep -q 'dofile' "$calls"

printf 'monitor auto-switcher tests passed\n'
