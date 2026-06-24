set -euo pipefail

last_state=""
last_opened=0
cooldown=300

notify() {
  notify-send -a "NetworkManager" "$@" >/dev/null 2>&1 || true
}

hypr_exec() {
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    hyprctl dispatch exec "$*" >/dev/null 2>&1 && return 0
  fi

  for socket in "$runtime_dir"/hypr/*/.socket.sock; do
    [ -S "$socket" ] || continue
    instance="${socket%/.socket.sock}"
    export HYPRLAND_INSTANCE_SIGNATURE="${instance##*/}"
    hyprctl dispatch exec "$*" >/dev/null 2>&1 && return 0
  done

  return 1
}

while true; do
  state="$(nmcli -t -f CONNECTIVITY general status 2>/dev/null || printf 'unknown')"
  now="$(date +%s)"

  case "$state" in
    portal|limited)
      if [ "$state" != "$last_state" ] || [ $((now - last_opened)) -ge "$cooldown" ]; then
        notify "Captive portal or limited network" "Connectivity is '$state'; opening plain-HTTP login pages."
        sleep 2
        if hypr_exec "@CAPTIVE_PORTAL_BROWSER@"; then
          last_opened="$now"
        fi
      fi
      ;;
    full)
      if [ "$last_state" = "portal" ] || [ "$last_state" = "limited" ]; then
        notify "Network online" "Connectivity check is full."
      fi
      ;;
  esac

  last_state="$state"
  sleep 10
done
