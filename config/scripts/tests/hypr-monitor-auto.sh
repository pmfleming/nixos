set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export HYPR_MONITOR_AUTO_LIB_ONLY=1
# shellcheck source=/dev/null
source "$script_path"

custom_monitors_file="$test_root/monitors.lua"
connected=0
active=1
fail_reload=0
calls="$test_root/calls"
: > "$calls"
external_connected() { [ "$connected" = 1 ]; }
hyprctl_command() {
  if [ "$1" = -j ]; then
    if [ "$active" = 1 ]; then
      printf '%s\n' '[{"name":"HDMI-A-1","disabled":false,"width":3440,"height":1440,"dpmsStatus":false}]'
    elif [ "$active" = unavailable ]; then
      return 1
    elif [ "$active" = empty ]; then
      return 0
    else
      printf '%s\n' '[]'
    fi
    return
  fi
  printf '%s\n' "$*" >> "$calls"
  [ "$fail_reload" = 0 ]
}

printf '%s\n' 'hl.monitor({ output = "eDP-1", mode = "1920x1200@60.0", scale = 1.25 })' > "$custom_monitors_file"
connected=1
apply_state force
[ "$last_state" = external ]
grep -q 'disabled = true' "$calls"

# A cable can stay connected throughout wake while Hyprland has no output.
active=0
: > "$calls"
apply_state
[ "$last_state" = recovering ]
grep -q 'output = "eDP-1", mode = "preferred"' "$calls"
if grep -q 'disabled = true' "$calls"; then exit 1; fi
apply_state
[ "$(wc -l < "$calls")" -eq 1 ]

# Reconciliation must recover without another socket event, and keep normal
# idle DPMS blanking intact when the external output is otherwise active.
active=1
: > "$calls"
apply_state
[ "$last_state" = external ]
grep -q 'disabled = true' "$calls"
apply_state
[ "$(wc -l < "$calls")" -eq 2 ]

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

# Never load an external-only saved layout before its output is available.
active=0
: > "$calls"
apply_state
[ "$last_state" = recovering ]
if grep -q 'dofile\|disabled = true' "$calls"; then exit 1; fi
active=1
apply_state
[ "$last_state" = custom ]
grep -q 'dofile' "$calls"

# Failed fallback commands must not claim recovery or suppress another attempt.
active=0
fail_reload=1
apply_state
[ "$last_state" = custom ]
fail_reload=0
apply_state
[ "$last_state" = recovering ]

# Socket timeouts drive reconciliation; EOF exits instead of spinning.
: > "$calls"
active=1
monitor_events < <(sleep 2.2)
[ "$last_state" = custom ]
grep -q 'dofile' "$calls"

# Missing IPC replies cannot be interpreted as a usable external output.
for active in unavailable empty; do
  last_state=external
  : > "$calls"
  apply_state
  [ "$last_state" = recovering ]
  grep -q 'output = "eDP-1", mode = "preferred"' "$calls"
  if grep -q 'disabled = true' "$calls"; then exit 1; fi
done

# Config reload must restore policy once; resulting monitor events must settle.
active=1
last_state=custom
: > "$calls"
monitor_events <<< $'configreloaded>>\nmonitoradded>>HDMI-A-1'
[ "$last_state" = custom ]
[ "$(wc -l < "$calls")" -eq 1 ]
grep -q 'dofile' "$calls"

printf 'monitor auto-switcher tests passed\n'
