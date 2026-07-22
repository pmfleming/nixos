last_state=""

restart_waybar() {
  # Waybar can stay attached to the disabled output after a monitor swap.
  # Restart it through Hyprland so it binds to the currently visible output.
  sleep 0.5
  pkill -u "$(id -u)" -f '(^|/)waybar( |$)' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -u "$(id -u)" -f '(^|/)waybar( |$)' >/dev/null || break
    sleep 0.2
  done
  # In a Lua-configured session, legacy `hyprctl dispatch exec ...` is parsed
  # as Lua and fails. Evaluate the equivalent Lua API call explicitly.
  hyprctl eval 'hl.exec_cmd("@WAYBAR@ >/dev/null 2>&1")' >/dev/null || true
}

external_connected() {
  for status in /sys/class/drm/card*-DP-*/status /sys/class/drm/card*-HDMI-A-*/status; do
    [ -e "$status" ] || continue
    grep -q '^connected$' "$status" && return 0
  done
  return 1
}

custom_monitors_file="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.lua"

custom_monitor_config_matches_state() {
  [ -f "$custom_monitors_file" ] || return 1
  grep -Eq '^[[:space:]]*hl\.monitor\(' "$custom_monitors_file" || return 1

  if external_connected; then
    # Respect saved nwg-displays external layouts; ignore stale internal-only configs.
    # Match external connector names only in the output field; otherwise eDP-1
    # is accidentally treated as a DP-* external output.
    grep -Eq '^[[:space:]]*hl\.monitor\(\{.*output[[:space:]]*=[[:space:]]*"((DP-|HDMI-A-)|desc:)' "$custom_monitors_file"
  else
    # A saved external-only layout usually contains `eDP-1, disabled = true`;
    # do not mistake that stale disabled rule for a usable internal layout.
    grep -E '^[[:space:]]*hl\.monitor\(\{.*output[[:space:]]*=[[:space:]]*"eDP-' "$custom_monitors_file" \
      | grep -Eqv 'disabled[[:space:]]*=[[:space:]]*true'
  fi
}

apply_state() {
  force="${1:-}"

  if custom_monitor_config_matches_state; then
    state="custom"
  elif external_connected; then
    state="external"
  else
    state="internal"
  fi
  [ "$force" = force ] || [ "$state" != "$last_state" ] || return 0

  # `hyprctl keyword` only supports the legacy config parser. Apply monitor
  # rules through the Lua API used by the active Hyprland configuration.
  case "$state" in
    external)
      hyprctl eval 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = @MONITOR_SCALE@ })' >/dev/null || true
      hyprctl eval 'hl.monitor({ output = "eDP-1", disabled = true })' >/dev/null || true
      ;;
    internal)
      hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = @MONITOR_SCALE@ })' >/dev/null || true
      ;;
  esac
  restart_waybar
  last_state="$state"
}

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

find_socket() {
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    socket="$runtime_dir/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
    [ -S "$socket" ] && printf '%s\n' "$socket" && return 0
  fi

  for socket in "$runtime_dir"/hypr/*/.socket2.sock; do
    [ -S "$socket" ] && printf '%s\n' "$socket" && return 0
  done

  return 1
}

export_instance_from_socket() {
  instance="${1%/.socket2.sock}"
  export HYPRLAND_INSTANCE_SIGNATURE="${instance##*/}"
}

while true; do
  while ! socket="$(find_socket)"; do
    sleep 1
  done

  export_instance_from_socket "$socket"
  apply_state

  socat -U - UNIX-CONNECT:"$socket" | while IFS= read -r event; do
    case "$event" in
      monitoradded*|monitorremoved*|configreloaded*) apply_state force ;;
    esac
  done

  sleep 1
done
