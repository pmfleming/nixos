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
  hyprctl dispatch exec "@WAYBAR@ >/dev/null 2>&1" >/dev/null || true
}

external_connected() {
  for status in /sys/class/drm/card*-DP-*/status /sys/class/drm/card*-HDMI-A-*/status; do
    [ -e "$status" ] || continue
    grep -q '^connected$' "$status" && return 0
  done
  return 1
}

custom_monitors_file="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.conf"

custom_monitor_config_matches_state() {
  [ -f "$custom_monitors_file" ] || return 1
  grep -Eq '^[[:space:]]*monitor[[:space:]]*=' "$custom_monitors_file" || return 1

  if external_connected; then
    # Respect saved nwg-displays external layouts; ignore stale internal-only configs.
    # Match external connector names only at the start of the monitor field;
    # otherwise eDP-1 is accidentally treated as a DP-* external output.
    grep -Eq '^[[:space:]]*monitor[[:space:]]*=[[:space:]]*((DP-|HDMI-A-)|desc:)' "$custom_monitors_file"
  else
    grep -Eq '^[[:space:]]*monitor[[:space:]]*=[[:space:]]*eDP-' "$custom_monitors_file"
  fi
}

apply_state() {
  if custom_monitor_config_matches_state; then
    state="custom"
    if [ "$state" != "$last_state" ]; then
      restart_waybar
      last_state="$state"
    fi
    return 0
  fi

  if external_connected; then
    state="external"
    if [ "$state" != "$last_state" ]; then
      hyprctl keyword monitor ",preferred,auto,1.25" >/dev/null || true
      hyprctl keyword monitor "eDP-1,disable" >/dev/null || true
      restart_waybar
      last_state="$state"
    fi
  else
    state="internal"
    if [ "$state" != "$last_state" ]; then
      hyprctl keyword monitor "eDP-1,preferred,auto,1.25" >/dev/null || true
      restart_waybar
      last_state="$state"
    fi
  fi
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
      monitoradded*|monitorremoved*|configreloaded*) apply_state ;;
    esac
  done

  sleep 1
done
