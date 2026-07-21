set -euo pipefail
# shellcheck source=/dev/null
source @ROFI_SCRIPT_HELPERS@

muted="@PALETTE_MUTED@"
tab=$'\t'

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

rofi_icon_row() {
  local search="$1"
  local info="$2"
  local display="$3"
  local icon="${4:-}"
  local active="${5:-false}"

  printf '%s\0display\x1f%s' "$search" "$display"
  [ -z "$info" ] || printf '\x1finfo\x1f%s' "$info"
  [ -z "$icon" ] || printf '\x1ficon\x1f%s' "$icon"
  [ "$active" != "true" ] || printf '\x1factive\x1ftrue'
  printf '\n'
}

desktop_app_dirs() {
  declare -A seen=()
  local dir

  dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  printf '%s\n' "$dir"
  seen["$dir"]=1

  local data_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  data_dirs="$data_dirs:/run/current-system/sw/share"
  [ -z "${USER:-}" ] || data_dirs="$data_dirs:/etc/profiles/per-user/$USER/share"

  local -a dirs=()
  IFS=':' read -r -a dirs <<< "$data_dirs"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    dir="$dir/applications"
    [ -z "${seen[$dir]+x}" ] || continue
    seen["$dir"]=1
    printf '%s\n' "$dir"
  done
}

# Parse every passed .desktop file in a single awk pass. Emits one
# "path<TAB>name<TAB>icon<TAB>wmclass<TAB>exec" line per valid Application entry.
parse_desktops() {
  awk -F= '
    function flush(   ok) {
      ok = (file != "" && type == "Application" && name != "" && exec != "" && nodisplay != "true" && hidden != "true")
      if (ok) printf "%s\t%s\t%s\t%s\t%s\n", file, name, icon, wmclass, exec
      type = ""; name = ""; icon = ""; wmclass = ""; exec = ""
      nodisplay = ""; hidden = ""; in_entry = 0; done_entry = 0
    }
    FNR == 1 { flush(); file = FILENAME }
    done_entry { next }
    $0 == "[Desktop Entry]" { in_entry = 1; next }
    /^\[/ { if (in_entry) done_entry = 1; next }
    !in_entry || /^[[:space:]]*($|#)/ { next }
    {
      key = $1
      val = substr($0, index($0, "=") + 1)
      if (key == "Type") type = val
      else if (key == "Name" && name == "") name = val
      else if (key == "Icon" && icon == "") icon = val
      else if (key == "StartupWMClass" && wmclass == "") wmclass = val
      else if (key == "Exec" && exec == "") exec = val
      else if (key == "NoDisplay") nodisplay = tolower(val)
      else if (key == "Hidden") hidden = tolower(val)
    }
    END { flush() }
  ' "$@"
}

DESKTOPS_LOADED=0
declare -a DESKTOP_IDS=()
declare -a DESKTOP_NAMES=()
declare -a DESKTOP_ICONS=()
declare -a DESKTOP_WMCLASSES=()
declare -A DESKTOP_INDEX_BY_ID=()
declare -A DESKTOP_BY_KEY=()

add_desktop_key() {
  local key idx
  key="$(lower "$1")"
  idx="$2"
  [ -n "$key" ] || return 0
  [ -z "${DESKTOP_BY_KEY[$key]+x}" ] || return 0
  DESKTOP_BY_KEY["$key"]="$idx"
}

load_desktops() {
  [ "$DESKTOPS_LOADED" -eq 0 ] || return 0
  DESKTOPS_LOADED=1

  local appdir file rel id idx name icon wmclass exec cmd
  local -a files=()
  declare -A seen_id=()
  declare -A file_id=()

  # Collect candidate files in $XDG_DATA_DIRS precedence order, first id wins.
  while IFS= read -r appdir; do
    [ -d "$appdir" ] || continue
    while IFS= read -r -d '' file; do
      rel="${file#"$appdir"/}"
      id="${rel//\//-}"
      [ -z "${seen_id[$id]+x}" ] || continue
      seen_id["$id"]=1
      file_id["$file"]="$id"
      files+=("$file")
    done < <(find -L "$appdir" -type f -name '*.desktop' -print0 2>/dev/null | sort -z)
  done < <(desktop_app_dirs)

  [ "${#files[@]}" -gt 0 ] || return 0

  # One awk pass over all files instead of one process per file.
  while IFS=$'\t' read -r file name icon wmclass exec; do
    id="${file_id[$file]:-}"
    [ -n "$id" ] || continue

    idx="${#DESKTOP_IDS[@]}"
    DESKTOP_IDS+=("$id")
    DESKTOP_NAMES+=("$name")
    DESKTOP_ICONS+=("$icon")
    DESKTOP_WMCLASSES+=("$wmclass")
    DESKTOP_INDEX_BY_ID["$id"]="$idx"

    add_desktop_key "${id%.desktop}" "$idx"
    add_desktop_key "$wmclass" "$idx"
    cmd="${exec%% *}"
    cmd="${cmd#\"}"
    cmd="${cmd%\"}"
    cmd="${cmd##*/}"
    add_desktop_key "$cmd" "$idx"
  done < <(parse_desktops "${files[@]}")
}

desktop_for_window() {
  local candidate key idx
  for candidate in "$1" "$2"; do
    key="$(lower "$candidate")"
    [ -n "$key" ] || continue
    if [ -n "${DESKTOP_BY_KEY[$key]+x}" ]; then
      idx="${DESKTOP_BY_KEY[$key]}"
      printf '%s' "${DESKTOP_IDS[$idx]}"
      return 0
    fi
  done
  return 1
}

WINDOWS_LOADED=0
declare -a GROUP_KEYS=()
declare -a GROUP_NAMES=()
declare -a GROUP_ICONS=()
declare -a GROUP_DESKTOP_IDS=()
declare -a GROUP_CLASSES=()
declare -a GROUP_COUNTS=()
declare -a GROUP_FIRST_ADDRS=()
declare -A GROUP_INDEX=()
declare -A RUNNING_DESKTOP_IDS=()
declare -a WINDOW_GROUP_KEYS=()
declare -a WINDOW_ADDRS=()
declare -a WINDOW_CLASSES=()
declare -a WINDOW_TITLES=()
declare -a WINDOW_WORKSPACES=()

load_windows() {
  [ "$WINDOWS_LOADED" -eq 0 ] || return 0
  WINDOWS_LOADED=1
  load_desktops
  command -v hyprctl >/dev/null 2>&1 || return 0

  local addr class initial title workspace desktop_id group_key gi idx name icon
  while IFS=$'\t' read -r addr class initial title workspace; do
    [ -n "$addr" ] || continue

    desktop_id="$(desktop_for_window "$class" "$initial" || true)"
    if [ -n "$desktop_id" ]; then
      group_key="desktop:$desktop_id"
      idx="${DESKTOP_INDEX_BY_ID[$desktop_id]}"
      name="${DESKTOP_NAMES[$idx]}"
      icon="${DESKTOP_ICONS[$idx]}"
      RUNNING_DESKTOP_IDS["$desktop_id"]=1
    else
      group_key="class:$(lower "$class")"
      name="$class"
      icon=""
    fi
    [ -n "$name" ] || name="Untitled"

    if [ -z "${GROUP_INDEX[$group_key]+x}" ]; then
      gi="${#GROUP_KEYS[@]}"
      GROUP_INDEX["$group_key"]="$gi"
      GROUP_KEYS+=("$group_key")
      GROUP_NAMES+=("$name")
      GROUP_ICONS+=("$icon")
      GROUP_DESKTOP_IDS+=("$desktop_id")
      GROUP_CLASSES+=("$class")
      GROUP_COUNTS+=(0)
      GROUP_FIRST_ADDRS+=("$addr")
    else
      gi="${GROUP_INDEX[$group_key]}"
    fi

    GROUP_COUNTS[gi]=$((GROUP_COUNTS[gi] + 1))
    WINDOW_GROUP_KEYS+=("$group_key")
    WINDOW_ADDRS+=("$addr")
    WINDOW_CLASSES+=("$class")
    WINDOW_TITLES+=("$title")
    WINDOW_WORKSPACES+=("$workspace")
  done < <(
    hyprctl clients -j 2>/dev/null \
      | jq -r '
          sort_by(.focusHistoryID // 999999)[]
          | select(.mapped != false)
          | [
              (.address // ""),
              (.class // ""),
              (.initialClass // ""),
              ((.title // "") | gsub("[\\t\\r\\n]"; " ")),
              (.workspace.name // "")
            ]
          | @tsv
        ' 2>/dev/null || true
  )
}

emit_main_menu() {
  load_windows
  rofi_common_headers "Apps" "Enter focuses/launches • → chooses running instances"
  rofi_header use-hot-keys true

  local i id name icon class count first_addr display search count_text
  for i in "${!GROUP_KEYS[@]}"; do
    id="${GROUP_DESKTOP_IDS[$i]}"
    name="${GROUP_NAMES[$i]}"
    icon="${GROUP_ICONS[$i]}"
    class="${GROUP_CLASSES[$i]}"
    count="${GROUP_COUNTS[$i]}"
    first_addr="${GROUP_FIRST_ADDRS[$i]}"

    if [ "$count" -gt 1 ]; then
      count_text=" ${count} windows ›"
    else
      count_text=" ›"
    fi

    display="$(markup_escape "$name")<span foreground=\"$muted\">$(markup_escape "$count_text")</span>"
    search="$name $id $class running"
    rofi_icon_row "$search" "app${tab}${GROUP_KEYS[$i]}${tab}$id${tab}$count${tab}$first_addr" "$display" "$icon" true
  done

  # Emit non-running apps alphabetically by display name (not by file id).
  local -a launch_order=()
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    launch_order+=("$i")
  done < <(
    for i in "${!DESKTOP_IDS[@]}"; do
      [ -z "${RUNNING_DESKTOP_IDS[${DESKTOP_IDS[$i]}]+x}" ] || continue
      printf '%s\t%s\n' "${DESKTOP_NAMES[$i]}" "$i"
    done | sort -f -t"$tab" -k1,1 | cut -f2
  )

  for i in "${launch_order[@]}"; do
    id="${DESKTOP_IDS[$i]}"
    name="${DESKTOP_NAMES[$i]}"
    icon="${DESKTOP_ICONS[$i]}"
    display="$(markup_escape "$name")"
    search="$name $id ${DESKTOP_WMCLASSES[$i]}"
    rofi_icon_row "$search" "launch${tab}$id" "$display" "$icon"
  done
}

emit_instances() {
  local key="$1"
  load_windows

  if [ -z "${GROUP_INDEX[$key]+x}" ]; then
    emit_main_menu
    return 0
  fi

  local gi name icon i title workspace class display search addr
  gi="${GROUP_INDEX[$key]}"
  name="${GROUP_NAMES[$gi]}"
  icon="${GROUP_ICONS[$gi]}"

  rofi_common_headers "$name" "Enter focuses an instance • ← returns to apps"
  rofi_header use-hot-keys true
  rofi_icon_row "back apps" "back" "<span foreground=\"$muted\">← Apps</span>" ""

  for i in "${!WINDOW_ADDRS[@]}"; do
    [ "${WINDOW_GROUP_KEYS[$i]}" = "$key" ] || continue
    addr="${WINDOW_ADDRS[$i]}"
    title="${WINDOW_TITLES[$i]}"
    workspace="${WINDOW_WORKSPACES[$i]}"
    class="${WINDOW_CLASSES[$i]}"
    [ -n "$title" ] || title="$name"

    display="$(markup_escape "$title")"
    [ -z "$workspace" ] || display="$display<span foreground=\"$muted\"> · $(markup_escape "$workspace")</span>"
    search="$title $class $workspace"
    rofi_icon_row "$search" "focus${tab}$addr" "$display" "$icon"
  done
}

focus_window() {
  local addr="$1"
  [ -n "$addr" ] || exit 0
  hyprctl dispatch "hl.dsp.focus({ window = [=[address:$addr]=] })" >/dev/null 2>&1 || true
}

launch_app() {
  local id="$1"
  [ -n "$id" ] || exit 0
  # Detach into a new session so the app outlives rofi's process group.
  # Intentionally expanded by the child sh, not this script.
  # shellcheck disable=SC2016
  setsid -f sh -c 'gtk-launch "$1" || gtk-launch "${1%.desktop}"' sh "$id" >/dev/null 2>&1 || true
}

if [ -z "${ROFI_RETV:-}" ]; then
  ROFI_CLIPBOARD_TARGET="$(hypr_active_window_paste_context)"
  export ROFI_CLIPBOARD_TARGET

  exec rofi \
    -show apps \
    -modes "apps:$0,run,window,bluetooth:rofi-bluetooth-menu,clipboard:rofi-clipboard-menu" \
    -i \
    -p "Apps" \
    -markup-rows \
    -show-icons \
    -kb-custom-1 "Right" \
    -kb-custom-2 "Left" \
    -kb-accept-alt "" \
    -kb-move-char-forward "Control+f" \
    -kb-move-char-back "Control+b"
fi

info="${ROFI_INFO:-}"
if [ "${ROFI_RETV:-}" = "11" ]; then
  emit_main_menu
  exit 0
fi

case "$info" in
  app"$tab"*)
    payload="${info#app"$tab"}"
    IFS=$'\t' read -r key desktop_id count first_addr <<< "$payload"
    if [ "${ROFI_RETV:-}" = "10" ]; then
      emit_instances "$key"
    elif [ -n "$first_addr" ]; then
      focus_window "$first_addr"
    else
      launch_app "$desktop_id"
    fi
    ;;
  launch"$tab"*)
    launch_app "${info#launch"$tab"}"
    ;;
  focus"$tab"*)
    focus_window "${info#focus"$tab"}"
    ;;
  back)
    emit_main_menu
    ;;
  *)
    emit_main_menu
    ;;
esac
