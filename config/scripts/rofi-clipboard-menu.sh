set -euo pipefail
# shellcheck source=/dev/null
source @ROFI_SCRIPT_HELPERS@

notify() {
  notify-send -a "Clipboard" "$@" >/dev/null 2>&1 || true
}

# cliphist renders binary entries as
# "[[ binary data <size> <unit> <type> <dims> ]]". Keep MIME/extension
# selection centralized so copied JPEG/WebP/GIF/etc. are not mislabeled as
# PNG screenshots.
clip_is_binary() {
  case "$1" in
    "[[ binary data "*) return 0 ;;
    *) return 1 ;;
  esac
}

clip_binary_meta() {
  meta="${1#\[\[ binary data }"
  printf '%s' "${meta% \]\]}"
}

clip_binary_type() {
  clip_is_binary "$1" || return 1
  read -r _size _unit type _rest <<< "$(clip_binary_meta "$1")"
  [ -n "${type:-}" ] || return 1
  printf '%s' "$type"
}

clip_mime_for_type() {
  case "$1" in
    png) printf 'image/png' ;;
    jpg|jpeg) printf 'image/jpeg' ;;
    webp) printf 'image/webp' ;;
    gif) printf 'image/gif' ;;
    bmp) printf 'image/bmp' ;;
    tif|tiff) printf 'image/tiff' ;;
    svg|svg+xml) printf 'image/svg+xml' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

clip_ext_for_type() {
  case "$1" in
    jpg|jpeg) printf 'jpg' ;;
    tif|tiff) printf 'tiff' ;;
    svg|svg+xml) printf 'svg' ;;
    png|webp|gif|bmp) printf '%s' "$1" ;;
    *) printf 'bin' ;;
  esac
}

clip_is_image_type() {
  case "$1" in
    png|jpg|jpeg|webp|gif|bmp|tif|tiff|svg|svg+xml) return 0 ;;
    *) return 1 ;;
  esac
}

clip_is_file_reference_preview() {
  case "$1" in
    file://*|copy\ file://*|cut\ file://*|copy\ \>\ file://*|cut\ \>\ file://*) return 0 ;;
    *) return 1 ;;
  esac
}

clipboard_row() {
  entry="$1"
  id="${entry%%"$tab"*}"
  preview="${entry#*"$tab"}"
  text="$preview"
  icon=$'\uf0ea'
  search="$preview"

  if clip_is_binary "$preview"; then
    text="$(clip_binary_meta "$preview")"
    text="${text//x/×}"
    type="$(clip_binary_type "$preview" || printf unknown)"
    icon=$'\uf1c0'
    search="$id binary $type $text"
    if clip_is_image_type "$type"; then
      icon=$'\uf03e'
      search="$id image $type pixels file uri path $text"
    fi
  elif clip_is_file_reference_preview "$preview"; then
    icon=$'\uf15b'
    search="file uri path $preview"
  fi

  display="$(printf '%-4s  %s  %s' "$id" "$icon" "$(markup_escape "$text")")"
  printf -v info 'paste\t%s' "$entry"
  rofi_row "$search" "$info" "$display"
}

# Resolve "backend|target|class" for the window focused before rofi
# opened. ROFI_DATA carries it across script reentry; ROFI_CLIPBOARD_TARGET
# is the launch-time export; the live query is the last-resort fallback.
clipboard_context() {
  printf '%s' "${ROFI_DATA:-${ROFI_CLIPBOARD_TARGET:-$(hypr_active_window_paste_context)}}"
}

split_paste_context() {
  context="$1"
  paste_backend="${context%%|*}"
  rest="${context#*|}"
  paste_target="${rest%%|*}"
  paste_class="${rest#*|}"
  [ "$paste_class" != "$rest" ] || paste_class=""
}

paste_shortcut_for_class() {
  case "$1" in
    com.mitchellh.ghostty|ghostty|Ghostty|Alacritty|alacritty|kitty|foot|footclient|org.wezfurlong.wezterm|org.gnome.Terminal|org.gnome.Console|org.kde.konsole|konsole|Ptyxis|dev.warp.Warp|com.raggesilver.BlackBox)
      printf 'CTRL SHIFT,V'
      ;;
    *)
      printf 'CTRL,V'
      ;;
  esac
}

delayed_paste() {
  context="$1"
  preview="$2"

  # Let rofi close and return focus before injecting paste. Without this
  # delay the shortcut is often delivered while rofi still owns focus.
  (
    sleep 0.20
    split_paste_context "$context"
    shortcut="$(paste_shortcut_for_class "$paste_class")"

    if [ "$paste_backend" = hyprland ]; then
      case "$paste_target" in
        ""|activewindow) ;;
        *) hyprctl dispatch focuswindow "$paste_target" >/dev/null 2>&1 || true ;;
      esac

      if hyprctl dispatch sendshortcut "$shortcut,$paste_target" >/dev/null 2>&1; then
        notify "Pasted from history" "$preview"
      else
        notify "Paste shortcut failed" "Item is on the clipboard; press paste manually."
      fi
    else
      notify "Paste shortcut failed" "Item is on the clipboard; press paste manually."
    fi
  ) >/dev/null 2>&1 &
}

decode_entry_to_file() {
  entry="$1"
  file="$2"

  printf '%s\n' "$entry" | cliphist decode > "$file"
}

image_file_from_entry() {
  entry="$1"
  id="${entry%%"$tab"*}"
  preview="${entry#*"$tab"}"
  type="$(clip_binary_type "$preview" || printf bin)"
  dir="$HOME/Pictures/Screenshots/clipboard-history"
  mkdir -p "$dir"
  file="$dir/clipboard-$id-$(date +%Y%m%d-%H%M%S).$(clip_ext_for_type "$type")"
  decode_entry_to_file "$entry" "$file"
  printf '%s' "$file"
}

copy_file_uri() {
  file="$1"
  printf 'file://%s\r\n' "$file" | wl-copy --sensitive --type text/uri-list
}

copy_text_entry() {
  entry="$1"
  tmp="$(mktemp)"
  printf '%s\n' "$entry" | cliphist decode > "$tmp"

  first=""
  second=""
  {
    IFS= read -r first || true
    IFS= read -r second || true
  } < "$tmp"

  case "$first:$second" in
    file://*:*)
      wl-copy --sensitive --type text/uri-list < "$tmp"
      ;;
    copy:file://*|cut:file://*)
      wl-copy --sensitive --type x-special/gnome-copied-files < "$tmp"
      ;;
    *)
      wl-copy --sensitive < "$tmp"
      ;;
  esac

  rm -f "$tmp"
}

emit_clipboard_menu() {
  context="$(clipboard_context)"
  rofi_common_headers "Paste" "Enter pastes • Shift+Enter sends image as file • → previews/annotates image"
  rofi_header use-hot-keys true
  rofi_header data "$context"
  rofi_row "clear clipboard history" "clear" "󰆴  Clear clipboard history"

  count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    clipboard_row "$entry"
  done < <(cliphist list 2>/dev/null || true)

  if [ "$count" -eq 0 ]; then
    rofi_static_row "no clipboard history" "No clipboard history"
  fi
}

paste_clipboard_to_target() {
  preview="$1"
  context="${2:-$(clipboard_context)}"

  # Hyprland sends paste to the window focused before rofi opened. wl-copy
  # --sensitive keeps selection from moving/reduplicating cliphist rows.
  delayed_paste "$context" "$preview"
}

paste_entry() {
  entry="$1"
  preview="${entry#*"$tab"}"

  if clip_is_binary "$preview"; then
    type="$(clip_binary_type "$preview" || printf '%s' unknown)"
    printf '%s\n' "$entry" | cliphist decode | wl-copy --sensitive --type "$(clip_mime_for_type "$type")"
  else
    copy_text_entry "$entry"
  fi

  paste_clipboard_to_target "$preview"
}

paste_image_file_entry() {
  entry="$1"
  file="$(image_file_from_entry "$entry")"
  copy_file_uri "$file"

  paste_clipboard_to_target "Image file: $file"
}

focus_satty() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    hyprctl dispatch focuswindow 'class:^(com\.gabm\.satty)$' >/dev/null 2>&1 && return 0
    sleep 0.05
  done
}

annotate_state_file() {
  state="$1"
  {
    IFS= read -r raw
    IFS= read -r edited
    IFS= read -r context
  } < "$state"
  tmp_dir="$(dirname "$state")"
  trap 'rm -rf "$tmp_dir"' EXIT

  satty \
    --filename "$raw" \
    --output-filename "$edited" \
    --resize smart \
    --early-exit \
    --actions-on-enter save-to-file \
    >/dev/null 2>&1 &
  satty_pid="$!"
  focus_satty
  wait "$satty_pid" || exit 0
  [ -s "$edited" ] || exit 0

  wl-copy --sensitive --type image/png < "$edited"
  paste_clipboard_to_target "Annotated image" "$context"
}

annotate_image_entry() {
  entry="$1"
  preview="${entry#*"$tab"}"
  type="$(clip_binary_type "$preview" || printf png)"
  tmp_dir="$(mktemp -d)"
  raw="$tmp_dir/input.$(clip_ext_for_type "$type")"
  edited="$tmp_dir/edited.png"
  state="$tmp_dir/state"

  decode_entry_to_file "$entry" "$raw"
  {
    printf '%s\n' "$raw"
    printf '%s\n' "$edited"
    printf '%s\n' "$(clipboard_context)"
  } > "$state"

  self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if ! hyprctl dispatch exec "$self --annotate-state $state" >/dev/null 2>&1; then
    "$self" --annotate-state "$state" >/dev/null 2>&1 &
  fi
}

if [ "${1:-}" = "--annotate-state" ]; then
  annotate_state_file "$2"
  exit 0
fi

if [ -z "${ROFI_RETV:-}" ]; then
  ROFI_CLIPBOARD_TARGET="$(hypr_active_window_paste_context)"
  export ROFI_CLIPBOARD_TARGET
  rofi_script_launch clipboard "Paste" -markup-rows -kb-custom-1 "Shift+Return" -kb-custom-2 "Right" -kb-accept-alt "" -kb-move-char-forward "Control+f"
fi

tab=$'\t'
info="${ROFI_INFO:-}"
image_entry_action() {
  case "$1" in
    annotate) annotate_image_entry "$2" ;;
    paste-file) paste_image_file_entry "$2" ;;
    *) paste_entry "$2" ;;
  esac
}

action="paste"
[ "${ROFI_RETV:-}" = "10" ] && action="paste-file"
[ "${ROFI_RETV:-}" = "11" ] && action="annotate"

case "$info" in
  clear)
    cliphist wipe
    notify "Clipboard history cleared"
    emit_clipboard_menu
    ;;
  paste"$tab"*)
    entry="${info#paste"$tab"}"
    preview="${entry#*"$tab"}"
    type="$(clip_binary_type "$preview" || true)"
    if [ -n "$type" ] && clip_is_image_type "$type"; then
      image_entry_action "$action" "$entry"
    else
      paste_entry "$entry"
    fi
    ;;
  *)
    emit_clipboard_menu
    ;;
esac
