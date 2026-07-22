markup_escape() {
  printf '%s' "$1" \
    | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g'
}

rofi_header() {
  printf '\0%s\x1f%s\n' "$1" "$2"
}

rofi_common_headers() {
  prompt="$1"
  message="${2:-}"
  rofi_header prompt "$prompt"
  rofi_header markup-rows true
  rofi_header no-custom true
  [ -z "$message" ] || rofi_header message "$message"
}

rofi_row() {
  local search="$1" info="$2" display="$3" icon="${4:-}" active="${5:-false}"

  printf '%s\0display\x1f%s' "$search" "$display"
  [ -z "$info" ] || printf '\x1finfo\x1f%s' "$info"
  [ -z "$icon" ] || printf '\x1ficon\x1f%s' "$icon"
  [ "$active" != true ] || printf '\x1factive\x1ftrue'
  printf '\n'
}

rofi_static_row() {
  search="$1"
  display="$2"

  printf '%s\0display\x1f%s\x1fnonselectable\x1ftrue\n' "$search" "$display"
}

rofi_script_launch() {
  mode="$1"
  prompt="$2"
  shift 2

  exec rofi -show "$mode" -modes "$mode:$0" -i -p "$prompt" "$@"
}

hypr_active_window_paste_context() {
  target="activewindow"
  class=""

  if ! command -v hyprctl >/dev/null 2>&1; then
    printf 'none|%s|%s\n' "$target" "$class"
    return 0
  fi

  while IFS= read -r line; do
    case "$line" in
      Window\ *\ -\>*)
        address="${line#Window }"
        address="${address%% ->*}"
        address="${address#0x}"
        [ -z "$address" ] || target="address:0x$address"
        ;;
      *class:\ *)
        class="${line#*: }"
        ;;
    esac
  done < <(hyprctl activewindow 2>/dev/null || true)

  printf 'hyprland|%s|%s\n' "$target" "$class"
}
