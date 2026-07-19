set -euo pipefail

flake_dir=/etc/nixos
flake_attr=@FLAKE_ATTR@

# Reached through report_rebuild, which is installed as an EXIT trap.
# shellcheck disable=SC2329
human_bytes() {
  numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}"
}

# Reached through report_rebuild, which is installed as an EXIT trap.
# shellcheck disable=SC2329
human_delta() {
  local bytes=${1:-0}

  if (( bytes < 0 )); then
    printf -- '-%s' "$(human_bytes "$((-bytes))")"
  else
    printf '+%s' "$(human_bytes "$bytes")"
  fi
}

# Reached through report_rebuild, which is installed as an EXIT trap.
# shellcheck disable=SC2329
human_duration() {
  local seconds=${1:-0}

  if (( seconds >= 3600 )); then
    printf '%dh %dm %ds' "$((seconds / 3600))" "$((seconds % 3600 / 60))" "$((seconds % 60))"
  elif (( seconds >= 60 )); then
    printf '%dm %ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%ds' "$seconds"
  fi
}

setup_terminal_styles() {
  style_reset=''
  style_bold=''
  style_dim=''
  style_green=''
  style_yellow=''
  style_red=''
  style_cyan=''

  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    style_reset=$'\033[0m'
    style_bold=$'\033[1m'
    style_dim=$'\033[2m'
    style_green=$'\033[32m'
    style_yellow=$'\033[33m'
    style_red=$'\033[31m'
    style_cyan=$'\033[36m'
  fi
}

usage_bar() {
  local percent=$1
  local width=20 filled index meter_color

  if [[ ! $percent =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '[unavailable]'
    return
  fi

  filled=$(awk -v value="$percent" -v width="$width" \
    'BEGIN { value = value > 100 ? 100 : value; printf "%.0f", value * width / 100 }')
  meter_color=$style_green
  if (( ${percent%.*} >= 90 )); then
    meter_color=$style_red
  elif (( ${percent%.*} >= 70 )); then
    meter_color=$style_yellow
  fi

  printf '['
  printf '%s' "$meter_color"
  for ((index = 0; index < filled; index++)); do
    printf '█'
  done
  printf '%s' "$style_dim"
  for ((index = filled; index < width; index++)); do
    printf '░'
  done
  printf '%s] %5s%%%s' "$style_reset" "$percent" "$style_reset"
}

system_cpu_counters() {
  local user nice system idle iowait irq softirq steal

  read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat
  printf '%s %s\n' \
    "$((user + nice + system + irq + softirq + steal))" \
    "$((user + nice + system + idle + iowait + irq + softirq + steal))"
}

system_network_counters() {
  awk -F '[: ]+' '
    NR > 2 && $2 != "lo" { received += $3; sent += $11 }
    END { printf "%.0f %.0f\n", received, sent }
  ' /proc/net/dev
}

system_disk_counters() {
  local device_id
  local read_sectors write_sectors

  device_id=$(findmnt -no MAJ:MIN -T /nix/store | tr -d ' ')
  if [[ -z $device_id || ! -r /sys/dev/block/$device_id/stat ]]; then
    return 1
  fi

  read -r _ _ read_sectors _ _ _ write_sectors _ _ _ _ _ _ _ _ _ _ \
    < "/sys/dev/block/$device_id/stat"
  printf '%s %s\n' "$((read_sectors * 512))" "$((write_sectors * 512))"
}

memory_counters() {
  awk '
    $1 == "MemTotal:" { total = $2 * 1024 }
    $1 == "MemAvailable:" { available = $2 * 1024 }
    END { printf "%.0f %.0f\n", total, available }
  ' /proc/meminfo
}

system_closure_bytes() {
  local closure_size

  read -r _ closure_size < <(
    nix path-info --closure-size /run/current-system 2>/dev/null
  ) || return 1
  [[ $closure_size =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$closure_size"
}

snapshot_store_paths() {
  nix path-info --all 2>/dev/null | sort -u
}

run_logged() {
  "$@" 2>&1 | tee -a "$activity_log"
  return "${PIPESTATUS[0]}"
}

render_summary() {
  local title=${overview_title:-REBUILD OVERVIEW}
  local status_icon status_color warning

  setup_terminal_styles
  if [[ $result == SUCCESS ]]; then
    status_icon='✓'
    status_color=$style_green
  else
    status_icon='✗'
    status_color=$style_red
  fi

  printf '\n%s╭─ %s ─────────────────────────────────────────────%s\n' \
    "$style_bold$style_cyan" "$title" "$style_reset"
  printf '│\n'
  printf '├─ %sOutcome%s\n' "$style_bold" "$style_reset"
  printf '│  %s%s %-17s%s %s\n' \
    "$status_color$style_bold" "$status_icon" "$result" "$style_reset" "$(human_duration "$elapsed")"
  printf '│\n'
  printf '├─ %sNix work%s\n' "$style_bold" "$style_reset"
  printf '│  Derivations built   %s%d%s\n' "$style_bold" "$built_count" "$style_reset"
  printf '│  Store paths copied  %s%d%s\n' "$style_bold" "$copied_count" "$style_reset"
  if [[ -n $copied_bytes ]]; then
    printf '│  Copied data         %s%s%s  uncompressed NAR size\n' \
      "$style_bold" "$(human_bytes "$copied_bytes")" "$style_reset"
  fi
  if [[ -n $new_path_bytes ]]; then
    printf '│  Store additions     %s%s%s  across %s new paths\n' \
      "$style_bold" "$(human_bytes "$new_path_bytes")" "$style_reset" "$new_path_count"
  else
    printf '│  Store additions     unavailable (store snapshot failed)\n'
  fi
  printf '│  Store filesystem    %s used; %s free now\n' \
    "$(human_delta "$store_used_delta")" "$(human_bytes "$store_available_after")"
  if [[ -n $closure_after ]]; then
    printf '│  System closure      %s' "$(human_bytes "$closure_after")"
    if [[ -n $closure_delta ]]; then
      printf '  (%s)\n' "$(human_delta "$closure_delta")"
    else
      printf '\n'
    fi
  fi

  printf '│\n'
  printf '├─ %sSystem load%s  %swhole-system during this run%s\n' \
    "$style_bold" "$style_reset" "$style_dim" "$style_reset"
  printf '│  CPU                 '
  usage_bar "$cpu_percent"
  printf '\n'
  if [[ -n $peak_memory_used ]]; then
    printf '│  Peak RAM            '
    usage_bar "$memory_percent"
    printf '  %s / %s\n' "$(human_bytes "$peak_memory_used")" "$(human_bytes "$memory_total")"
  fi
  printf '│  Network             ↓ %s   ↑ %s\n' \
    "$(human_bytes "$network_received_delta")" "$(human_bytes "$network_sent_delta")"
  if [[ -n $disk_read_delta ]]; then
    printf '│  Disk I/O            ↓ %s read   ↑ %s written\n' \
      "$(human_bytes "$disk_read_delta")" "$(human_bytes "$disk_written_delta")"
  fi

  if (( new_paths_ok && new_path_count > 0 )); then
    printf '│\n'
    printf '├─ %sLargest store additions%s\n' "$style_bold" "$style_reset"
    while IFS=$'\t' read -r size name; do
      printf '│  %8s  %s\n' "$(human_bytes "$size")" "$name"
    done < <(
      jq -r '
        to_entries
        | sort_by(.value.narSize // 0)
        | reverse
        | .[:5][]
        | "\(.value.narSize // 0)\t\(.key | split("/")[-1])"
      ' "$new_store_info"
    )
  fi

  printf '│\n'
  if (( ${#warnings[@]} )); then
    printf '├─ %s%sResource warnings%s\n' "$style_bold" "$style_red" "$style_reset"
    for warning in "${warnings[@]}"; do
      printf '│  %s⚠  %s%s\n' "$style_red$style_bold" "$warning" "$style_reset"
    done
  else
    printf '├─ %s%s✓ No excessive resource usage detected%s\n' \
      "$style_bold" "$style_green" "$style_reset"
  fi
  printf '%s╰────────────────────────────────────────────────────────%s\n' \
    "$style_cyan" "$style_reset"
}

preview_summary() {
  local gib=$((1024 * 1024 * 1024))
  local overview_title='REBUILD OVERVIEW · PREVIEW'
  local result=SUCCESS elapsed=83 built_count=14 copied_count=86
  local copied_bytes=$((100 * gib)) new_path_bytes=$((103 * gib)) new_path_count=112
  local store_used_delta=$((97 * gib)) store_available_after=$((311 * gib))
  local closure_after=$((42 * gib)) closure_delta=$((8 * gib))
  local cpu_percent=76.4 memory_percent=91.2
  local peak_memory_used=$((58 * gib)) memory_total=$((64 * gib))
  local network_received_delta=$((61 * gib)) network_sent_delta=$((2 * gib))
  local disk_read_delta=$((118 * gib)) disk_written_delta=$((147 * gib))
  local new_paths_ok=0 new_store_info=''
  local -a warnings=(
    'large Nix copy/substitution: 100.0GiB uncompressed NAR size'
    'heavy whole-system disk writes: 147.0GiB'
    'whole-system memory pressure peaked at 91.2%'
  )

  render_summary
  printf '%sPreview only: these are illustrative values, not measurements from a rebuild.%s\n' \
    "$style_dim" "$style_reset"
}

# Invoked by the EXIT trap below; ShellCheck does not follow trap handlers.
# shellcheck disable=SC2329
report_rebuild() {
  local exit_status=$?
  local finished_at elapsed result
  local cpu_busy_after cpu_total_after cpu_busy_delta cpu_total_delta cpu_percent='unknown'
  local network_received_after network_sent_after network_received_delta network_sent_delta
  local disk_read_after='' disk_written_after='' disk_read_delta='' disk_written_delta=''
  local store_used_after store_available_after store_used_delta
  local closure_after='' closure_delta=''
  local peak_memory_used='' memory_percent='unknown'
  local store_snapshot_after_ok=0 new_paths_ok=0
  local new_path_count='' new_path_bytes='' copied_count=0 copied_bytes='' built_count=0
  local size name
  local -a warnings=()

  trap - EXIT
  set +e

  if [[ -n ${memory_monitor_pid:-} ]]; then
    kill "$memory_monitor_pid" 2>/dev/null
    wait "$memory_monitor_pid" 2>/dev/null
  fi

  finished_at=$(date +%s)
  elapsed=$((finished_at - started_at))
  if (( exit_status == 0 )); then
    result=SUCCESS
  else
    result="FAILED (exit $exit_status)"
  fi

  read -r cpu_busy_after cpu_total_after < <(system_cpu_counters)
  cpu_busy_delta=$((cpu_busy_after - cpu_busy_before))
  cpu_total_delta=$((cpu_total_after - cpu_total_before))
  if (( cpu_total_delta > 0 )); then
    cpu_percent=$(awk -v busy="$cpu_busy_delta" -v total="$cpu_total_delta" \
      'BEGIN { printf "%.1f", busy * 100 / total }')
  fi

  read -r network_received_after network_sent_after < <(system_network_counters)
  network_received_delta=$((network_received_after - network_received_before))
  network_sent_delta=$((network_sent_after - network_sent_before))

  if [[ -n $disk_read_before && -n $disk_written_before ]] && \
    read -r disk_read_after disk_written_after < <(system_disk_counters); then
    disk_read_delta=$((disk_read_after - disk_read_before))
    disk_written_delta=$((disk_written_after - disk_written_before))
  fi

  read -r store_used_after store_available_after < <(
    df -B1 --output=used,avail /nix/store | tail -n 1
  )
  store_used_delta=$((store_used_after - store_used_before))

  closure_after=$(system_closure_bytes) || closure_after=''
  if [[ -n $closure_before && -n $closure_after ]]; then
    closure_delta=$((closure_after - closure_before))
  fi

  if [[ -s $peak_memory_file ]]; then
    peak_memory_used=$(tail -n 1 "$peak_memory_file")
    if (( memory_total > 0 )); then
      memory_percent=$(awk -v used="$peak_memory_used" -v total="$memory_total" \
        'BEGIN { printf "%.1f", used * 100 / total }')
    fi
  fi

  if snapshot_store_paths > "$store_paths_after"; then
    store_snapshot_after_ok=1
  fi
  if (( store_snapshot_before_ok && store_snapshot_after_ok )); then
    comm -13 "$store_paths_before" "$store_paths_after" > "$new_store_paths"
    if [[ -s $new_store_paths ]]; then
      if nix path-info --json --stdin < "$new_store_paths" > "$new_store_info" 2>/dev/null; then
        new_paths_ok=1
      fi
    else
      printf '{}\n' > "$new_store_info"
      new_paths_ok=1
    fi
  fi
  if (( new_paths_ok )); then
    new_path_count=$(jq 'length' "$new_store_info")
    new_path_bytes=$(jq '[.[] | (.narSize // 0)] | add // 0' "$new_store_info")
  fi

  sed -n "s/.*building '\([^']*\\.drv\)'.*/\1/p" "$activity_log" \
    | sort -u > "$built_paths"
  built_count=$(wc -l < "$built_paths")
  sed -n "s/.*copying path '\([^']*\)'.*/\1/p" "$activity_log" \
    | sort -u > "$copied_paths"
  copied_count=$(wc -l < "$copied_paths")
  if (( copied_count > 0 )) && \
    nix path-info --json --stdin < "$copied_paths" > "$copied_info" 2>/dev/null; then
    copied_bytes=$(jq '[.[] | (.narSize // 0)] | add // 0' "$copied_info")
  fi

  if [[ -n $new_path_bytes ]] && (( new_path_bytes >= 10 * 1024 * 1024 * 1024 )); then
    warnings+=("large Nix store addition: $(human_bytes "$new_path_bytes") across $new_path_count paths")
  fi
  if [[ -n $copied_bytes ]] && (( copied_bytes >= 5 * 1024 * 1024 * 1024 )); then
    warnings+=("large Nix copy/substitution: $(human_bytes "$copied_bytes") uncompressed NAR size")
  fi
  if [[ -n $disk_written_delta ]] && (( disk_written_delta >= 20 * 1024 * 1024 * 1024 )); then
    warnings+=("heavy whole-system disk writes: $(human_bytes "$disk_written_delta")")
  fi
  if (( network_received_delta >= 5 * 1024 * 1024 * 1024 )); then
    warnings+=("heavy whole-system network receive: $(human_bytes "$network_received_delta")")
  fi
  if [[ -n $peak_memory_used ]] && (( peak_memory_used * 100 >= memory_total * 90 )); then
    warnings+=("whole-system memory pressure peaked at ${memory_percent}%")
  fi
  if (( store_available_after < 20 * 1024 * 1024 * 1024 )); then
    warnings+=("low free disk space: $(human_bytes "$store_available_after") remains")
  fi
  if (( elapsed >= 30 * 60 )); then
    warnings+=("long runtime: $(human_duration "$elapsed")")
  fi

  render_summary

  rm -rf -- "$summary_tmp"
  exit "$exit_status"
}

if [ "$#" -gt 0 ] && [[ $1 != -* ]]; then
  flake_attr=$1
  shift
fi

if (( $# == 1 )) && [[ $1 == --summary-preview ]]; then
  preview_summary
  exit 0
fi

cd "$flake_dir"
mapfile -d '' -t untracked_nix < <(
  git ls-files --others --exclude-standard -z -- ':(glob)**/*.nix'
)
if (( ${#untracked_nix[@]} )); then
  printf 'Refusing to rebuild with untracked Nix files; Git flakes exclude them:\n' >&2
  printf '  %s\n' "${untracked_nix[@]}" >&2
  printf 'Run git add on these files, then rebuild again.\n' >&2
  exit 1
fi

summary_tmp=$(mktemp -d -t rebuild-summary.XXXXXXXX)
activity_log=$summary_tmp/activity.log
store_paths_before=$summary_tmp/store-paths-before
store_paths_after=$summary_tmp/store-paths-after
new_store_paths=$summary_tmp/new-store-paths
new_store_info=$summary_tmp/new-store-info.json
built_paths=$summary_tmp/built-paths
copied_paths=$summary_tmp/copied-paths
copied_info=$summary_tmp/copied-info.json
peak_memory_file=$summary_tmp/peak-memory-used
store_snapshot_before_ok=0
memory_monitor_pid=''

if snapshot_store_paths > "$store_paths_before"; then
  store_snapshot_before_ok=1
fi
closure_before=$(system_closure_bytes) || closure_before=''
read -r store_used_before _ < <(df -B1 --output=used,avail /nix/store | tail -n 1)
read -r cpu_busy_before cpu_total_before < <(system_cpu_counters)
read -r network_received_before network_sent_before < <(system_network_counters)
disk_read_before=''
disk_written_before=''
read -r disk_read_before disk_written_before < <(system_disk_counters) || true
read -r memory_total memory_available < <(memory_counters)
printf '%s\n' "$((memory_total - memory_available))" > "$peak_memory_file"

monitor_memory() {
  local total available used peak

  peak=$(<"$peak_memory_file")
  while true; do
    read -r total available < <(memory_counters)
    used=$((total - available))
    if (( used > peak )); then
      peak=$used
      printf '%s\n' "$peak" >> "$peak_memory_file"
    fi
    sleep 1
  done
}

started_at=$(date +%s)
monitor_memory &
memory_monitor_pid=$!
trap report_rebuild EXIT

status=0
if run_logged nix flake check "$flake_dir"; then
  :
else
  status=$?
fi
if (( status == 0 )); then
  if run_logged sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr" "$@"; then
    :
  else
    status=$?
  fi
fi
exit "$status"
