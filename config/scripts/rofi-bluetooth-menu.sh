set -euo pipefail
# shellcheck source=/dev/null
source @ROFI_SCRIPT_HELPERS@

notify() {
  notify-send -a "Bluetooth" "$@" >/dev/null 2>&1 || true
}

powered() {
  bluetoothctl show 2>/dev/null | awk -F': ' '/^[[:space:]]*Powered:/ { print $2; exit }'
}

device_field() {
  mac="$1"
  field="$2"
  bluetoothctl info "$mac" 2>/dev/null \
    | awk -F': ' -v field="$field" '$1 ~ "^[[:space:]]*" field "$" { print $2; exit }'
}

scan_devices_with_progress() {
  bluetoothctl power on >/dev/null 2>&1 || true
  timeout 8s bluetoothctl scan on >/dev/null 2>&1 &
  scan_pid="$!"
  elapsed=0

  while kill -0 "$scan_pid" 2>/dev/null; do
    rofi_header message "Scanning Bluetooth… ${elapsed}s elapsed."
    elapsed=$((elapsed + 1))
    sleep 1
  done

  wait "$scan_pid" >/dev/null 2>&1 || true
  bluetoothctl scan off >/dev/null 2>&1 || true
}

bluetooth_device_row() {
  id="$1"
  mac="$2"
  name="$3"
  [ -n "$name" ] || name="$mac"

  connected="$(device_field "$mac" Connected || true)"
  paired="$(device_field "$mac" Paired || true)"
  trusted="$(device_field "$mac" Trusted || true)"

  marker=" "
  status="new"
  if [ "$connected" = "yes" ]; then
    marker="●"
    status="connected"
  elif [ "$paired" = "yes" ]; then
    status="paired"
  fi
  [ "$trusted" = "yes" ] && status="$status trusted"

  key="$(printf '%02d' "$id")"
  safe_name="$(markup_escape "$name")"
  display="$(printf '%s  %s  %-34.34s  %s' "$key" "$marker" "$safe_name" "$status")"
  printf -v info 'device\t%s\t%s' "$mac" "$name"
  rofi_row "$name $mac" "$info" "$display"
}

emit_bluetooth_menu() {
  message="${1:-Enter connects/disconnects}"
  rofi_common_headers "Bluetooth" "$message"

  if ! bluetoothctl show >/dev/null 2>&1; then
    rofi_static_row "no controller" "󰂲  No Bluetooth controller found"
    return 0
  fi

  power="$(powered || true)"
  if [ "$power" = "yes" ]; then
    rofi_row "toggle bluetooth" "toggle" "t  󰂲  Turn Bluetooth off"
    rofi_row "scan bluetooth" "scan" "s  ⟳  Scan for devices"
  else
    rofi_row "toggle bluetooth" "toggle" "t  󰂯  Turn Bluetooth on"
  fi

  id=0
  while read -r _ mac name; do
    [ -n "${mac:-}" ] || continue
    id=$((id + 1))
    bluetooth_device_row "$id" "$mac" "${name:-$mac}"
  done < <(bluetoothctl devices 2>/dev/null | sort -k3)
}

connect_device() {
  mac="$1"
  name="$2"

  bluetoothctl power on >/dev/null 2>&1 || true
  bluetoothctl agent on >/dev/null 2>&1 || true
  bluetoothctl default-agent >/dev/null 2>&1 || true

  connected="$(device_field "$mac" Connected || true)"
  paired="$(device_field "$mac" Paired || true)"

  if [ "$connected" = "yes" ]; then
    if bluetoothctl disconnect "$mac" >/dev/null 2>&1; then
      notify "Disconnected" "$name"
      exit 0
    fi
    notify "Disconnect failed" "$name"
    exit 1
  fi

  if [ "$paired" != "yes" ]; then
    bluetoothctl pair "$mac" >/dev/null 2>&1 || true
  fi
  bluetoothctl trust "$mac" >/dev/null 2>&1 || true

  if bluetoothctl connect "$mac" >/dev/null 2>&1; then
    notify "Connected" "$name"
  else
    notify "Connection failed" "$name"
    exit 1
  fi
}

if [ -z "${ROFI_RETV:-}" ]; then
  rofi_script_launch bluetooth "Bluetooth" -markup-rows
fi

tab=$'\t'
info="${ROFI_INFO:-}"
case "$info" in
  toggle)
    if [ "$(powered || true)" = "yes" ]; then
      bluetoothctl power off >/dev/null 2>&1 || true
      notify "Bluetooth off"
      emit_bluetooth_menu "Bluetooth is off."
    else
      bluetoothctl power on >/dev/null 2>&1 || true
      notify "Bluetooth on"
      emit_bluetooth_menu "Bluetooth is on."
    fi
    ;;
  scan)
    rofi_common_headers "Bluetooth" "Scanning Bluetooth…"
    rofi_static_row "scanning" "⟳  Scanning for Bluetooth devices…"
    scan_devices_with_progress
    emit_bluetooth_menu "Bluetooth scan complete."
    ;;
  device"$tab"*)
    rest="${info#device"$tab"}"
    mac="${rest%%"$tab"*}"
    name="${rest#*"$tab"}"
    connect_device "$mac" "${name:-$mac}"
    ;;
  *)
    power="$(powered || true)"
    emit_bluetooth_menu "Enter connects/disconnects • current: Bluetooth ${power:-unknown}"
    ;;
esac
