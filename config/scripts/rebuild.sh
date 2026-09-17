set -euo pipefail

# shellcheck source=/dev/null
source "${NIXOS_DEPLOYMENT_LOCK_HELPER:-@DEPLOYMENT_LOCK_HELPER@}"

flake_dir=@CONFIG_DIRECTORY@
flake_attr=@FLAKE_ATTR@
local_build_helper=${NIXOS_LOCAL_BUILD_HELPER:-@LOCAL_BUILD_HELPER@}
source_state_helper=@SOURCE_STATE_HELPER@
approval_helper=@APPROVAL_HELPER@
# Fail closed: nixos-rebuild has aliases and deployment modes that bypass our
# checked snapshot. Only accept build tuning, never arbitrary Nix options.
build_arguments=()
parse_build_arguments() {
  local argument value

  while (($#)); do
    argument=$1
    shift
    case "$argument" in
      --verbose|-v|--quiet|--print-build-logs|-L|--show-trace|--keep-going|-k|--keep-failed|-K|--fallback|--repair|--offline)
        build_arguments+=( "$argument" )
        ;;
      --max-jobs|-j|--cores|--max-jobs=*|--cores=*|-j?*)
        case "$argument" in
          *=*) value=${argument#*=}; argument=${argument%%=*} ;;
          -j?*) value=${argument#-j}; argument=--max-jobs ;;
          *)
            if (($# == 0)); then
              printf 'Missing value for %s.\n' "$argument" >&2
              return 2
            fi
            value=$1
            shift
            ;;
        esac
        [[ $argument != -j ]] || argument=--max-jobs
        if [[ ! $value =~ ^[0-9]+$ ]] && [[ $argument != --max-jobs || $value != auto ]]; then
          printf 'Invalid value for %s: %s\n' "$argument" "$value" >&2
          return 2
        fi
        build_arguments+=( "$argument" "$value" )
        ;;
      *)
        printf 'rebuild owns source selection and local deployment; unsupported argument: %s\n' "$argument" >&2
        printf 'Supported: -v, --quiet, -L, --show-trace, -k, -K, --fallback, --repair, --offline, -j/--max-jobs N|auto, --cores N.\n' >&2
        return 2
        ;;
    esac
  done
}
parse_build_arguments "$@"
shelllist_daemons=(
  app-daemon.service
  bar-daemon.service
  bt-daemon.service
  clip-daemon.service
  nm-daemon.service
)
shelllist_units=( "${shelllist_daemons[@]}" shelllist.service )

state_home=${XDG_STATE_HOME:-${HOME:?HOME is not set}/.local/state}
log_dir="$state_home/nixos-rebuild"
umask 077
mkdir -p "$log_dir"
find "$log_dir" -maxdepth 1 -type f -name 'rebuild-*.log' -mtime +30 -delete
log_file="$log_dir/rebuild-$(date --utc +%Y%m%dT%H%M%SZ)-$$.running.log"
: > "$log_file"
ln -sfn "$(basename "$log_file")" "$log_dir/latest.log"
# Keep the terminal descriptors so the EXIT handler can drain the asynchronous
# logger before it reads the log and renders the summary.
exec 3>&1 4>&2
exec > >(tee -a "$log_file" >&3) 2>&1
log_writer_pid=$!

started_at=$(date +%s)
system_before=$(readlink -f /run/current-system 2>/dev/null || true)
rebuild_stage=initialization
session_result='not reached'
baseline_result='not reached'
temporary_file=
snapshot_dir=

human_duration() {
  local seconds=$1

  if ((seconds >= 3600)); then
    printf '%dh %dm %ds' "$((seconds / 3600))" "$((seconds % 3600 / 60))" "$((seconds % 60))"
  elif ((seconds >= 60)); then
    printf '%dm %ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%ds' "$seconds"
  fi
}

human_bytes() {
  numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}"
}

human_byte_delta() {
  local bytes=${1:-0}

  if ((bytes < 0)); then
    printf -- '-%s' "$(human_bytes "$((-bytes))")"
  else
    printf '+%s' "$(human_bytes "$bytes")"
  fi
}

closure_bytes() {
  local output size

  output=$(nix path-info --closure-size "$1" 2>/dev/null) || return 1
  size=${output##*[[:space:]]}
  [[ $size =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

stage() {
  rebuild_stage=$1
  printf '\n==> %s\n' "$rebuild_stage"
}

finish() {
  local status=$?
  local copied_info disk_after elapsed final_log line outcome suffix system_after
  local closure_after='' copied_bytes='' store_available_after='' store_used_after=''
  local -A built_paths=() copied_paths=()

  trap - EXIT HUP INT TERM
  set +e
  release_deployment_lock
  [[ -z $temporary_file ]] || rm -f -- "$temporary_file"
  [[ -z $snapshot_dir ]] || rm -rf -- "$snapshot_dir"

  # Close the pipe and wait for tee so every final build event is available to
  # the summary parser. Summary output is appended with a separate tee below.
  exec 1>&3 2>&4
  wait "$log_writer_pid"

  while IFS= read -r line; do
    if [[ $line =~ ^building\ \'([^\']+\.drv)\' ]]; then
      built_paths["${BASH_REMATCH[1]}"]=1
    elif [[ $line =~ ^copying\ path\ \'([^\']+)\' ]]; then
      copied_paths["${BASH_REMATCH[1]}"]=1
    fi
  done < "$log_file"

  if ((${#copied_paths[@]})); then
    temporary_file=$(mktemp "$log_dir/copied-paths.XXXXXXXX")
    printf '%s\n' "${!copied_paths[@]}" > "$temporary_file"
    if copied_info=$(nix path-info --json --stdin < "$temporary_file" 2>/dev/null); then
      copied_bytes=$(jq -r '[.[] | (.narSize // 0)] | add // 0' <<< "$copied_info")
    fi
    rm -f -- "$temporary_file"
    temporary_file=
  fi

  elapsed=$(($(date +%s) - started_at))
  system_after=$(readlink -f /run/current-system 2>/dev/null || true)
  [[ -z $system_after ]] || closure_after=$(closure_bytes "$system_after")
  disk_after=$(df -B1 --output=used,avail /nix/store 2>/dev/null | tail -n 1) || disk_after=
  if [[ $disk_after =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
    store_used_after=${BASH_REMATCH[1]}
    store_available_after=${BASH_REMATCH[2]}
  fi

  if ((status == 0)); then
    outcome=SUCCESS
  else
    outcome=FAILED
  fi
  suffix=${outcome,,}
  final_log=${log_file%.running.log}.$suffix.log
  if mv -- "$log_file" "$final_log"; then
    log_file=$final_log
  fi
  ln -sfn "$(basename "$log_file")" "$log_dir/latest.log"
  if ((status != 0)); then
    ln -sfn "$(basename "$log_file")" "$log_dir/latest-failed.log"
  fi

  {
    printf '\n=== REBUILD %s (%s) ===\n' "$outcome" "$(human_duration "$elapsed")"
    if ((status != 0)); then
      printf 'Failed at:  %s (exit %d)\n' "$rebuild_stage" "$status"
    fi
    printf 'Nix work:   %d derivations built; %d store paths copied' \
      "${#built_paths[@]}" "${#copied_paths[@]}"
    [[ -z $copied_bytes ]] || printf ' (%s)' "$(human_bytes "$copied_bytes")"
    printf '\n'
    if [[ -n $closure_after ]]; then
      printf 'Closure:    %s' "$(human_bytes "$closure_after")"
      [[ -z $closure_before ]] || \
        printf ' (%s)' "$(human_byte_delta "$((closure_after - closure_before))")"
      printf '\n'
    fi
    if [[ -n $store_used_after && -n $store_available_after ]]; then
      printf 'Nix store:  '
      [[ -z $store_used_before ]] || \
        printf '%s used; ' "$(human_byte_delta "$((store_used_after - store_used_before))")"
      printf '%s free\n' "$(human_bytes "$store_available_after")"
    fi
    if [[ -n $system_before && -n $system_after ]]; then
      if [[ $system_before == "$system_after" ]]; then
        printf 'System:     unchanged (%s)\n' "$(basename "$system_after")"
      else
        printf 'System:     %s -> %s\n' "$(basename "$system_before")" "$(basename "$system_after")"
      fi
    fi
    [[ $session_result == 'not reached' ]] || printf 'Session:    %s\n' "$session_result"
    [[ $baseline_result == 'not reached' ]] || printf 'Baseline:   %s\n' "$baseline_result"
    printf 'Log:        %s\n' "$log_file"

    if [[ -n $system_before && -n $system_after && $system_before != "$system_after" ]]; then
      printf '\nPackage changes:\n'
      nix store diff-closures "$system_before" "$system_after" || \
        printf '  (closure diff unavailable)\n'
    fi
  } 2>&1 | tee -a "$log_file"

  exec 3>&- 4>&-
  exit "$status"
}

closure_before=
store_used_before=
disk_before=
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n $system_before ]]; then
  closure_before=$(closure_bytes "$system_before") || closure_before=
fi
disk_before=$(df -B1 --output=used /nix/store 2>/dev/null | tail -n 1) || disk_before=
if [[ $disk_before =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
  store_used_before=${BASH_REMATCH[1]}
fi

printf 'Rebuild started; full log: %s\n' "$log_file"
if (($#)); then
  printf 'nixos-rebuild arguments:'
  printf ' %q' "$@"
  printf '\n'
fi

# Do not let two interactive rebuilds update the lock and switch concurrently.
exec 9>"$log_dir/rebuild.lock"
if ! flock -n 9; then
  printf 'Another rebuild is already running (see %s/latest.log).\n' "$log_dir" >&2
  exit 75
fi

stage 'Checking all local worktrees'
cd "$flake_dir"
python3 "$source_state_helper" preflight "$local_build_helper" "$flake_dir"
# The preflight above only discovers sources; authenticate before snapshot
# resolution, compatibility checks, and the expensive system build.
stage 'Authorizing the generation switch'
/run/wrappers/bin/sudo -v

stage 'Acquiring the shared deployment lock'
acquire_deployment_lock

# CO-DEVELOPMENT INVARIANT: every daemon uses ONE current local framework.
# Include tracked uncommitted edits. Snapshot once so edits during a long check
# cannot change the graph subsequently deployed. Never persist local-project
# pins or replace this with flake update / --no-write-lock-file alone.
stage 'Snapshotting current local worktrees'
snapshot_dir=$(mktemp -d)
snapshot_json=$(python3 "$source_state_helper" prepare "$local_build_helper" \
  "$flake_dir" "$snapshot_dir/sources" "$snapshot_dir/baseline.json")
printf '%s\n' "$snapshot_json" | jq .
snapshot_flake=$(jq -er .flake <<< "$snapshot_json")

stage 'Running framework, daemon, Shelllist, and configuration checks'
nix flake check "$snapshot_flake" --no-update-lock-file --keep-going "${build_arguments[@]}"

# Activation can fail after Home Manager has stopped graphical services. Save
# the switch status, then make a best effort to put the complete stack back in
# a known state before returning that status.
switch_status=0
failed_stage=
stage 'Building and switching the NixOS generation'
if /run/wrappers/bin/sudo nixos-rebuild switch --flake "$snapshot_flake#$flake_attr" --no-update-lock-file "${build_arguments[@]}"; then
  :
else
  switch_status=$?
  failed_stage=$rebuild_stage
  printf 'The generation switch failed; recovering the Shelllist stack.\n' >&2
fi

stage 'Refreshing graphical services'
stack_status=0
remember_stack_failure() {
  local status

  "$@" && return 0
  status=$?
  ((stack_status != 0)) || stack_status=$status
  printf 'Graphical recovery command failed (exit %d):' "$status" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  return 0
}
if /run/wrappers/bin/sudo systemctl --quiet is-active bar-battery-helper.service; then
  if ! /run/wrappers/bin/sudo systemctl restart bar-battery-helper.service; then
    printf 'Warning: bar-battery-helper could not be restarted.\n' >&2
  fi
fi

if systemctl --user --quiet is-active graphical-session.target; then
  remember_stack_failure systemctl --user daemon-reload
  remember_stack_failure systemctl --user restart "${shelllist_daemons[@]}"
  # Always restart the frontend, even if a daemon failed.
  remember_stack_failure systemctl --user restart shelllist.service
  # systemctl is-active with multiple units succeeds if ANY unit is active.
  # Check individually so a running frontend cannot mask a crashed daemon.
  for unit in "${shelllist_units[@]}"; do
    if systemctl --user --quiet is-active "$unit"; then
      :
    else
      unit_status=$?
      ((stack_status != 0)) || stack_status=$unit_status
      printf 'Graphical service is not active: %s (exit %d)\n' "$unit" "$unit_status" >&2
    fi
  done

  if ((stack_status == 0)); then
    session_result='Shelllist stack restarted'
  else
    session_result='Shelllist recovery failed'
    [[ -n $failed_stage ]] || failed_stage=$rebuild_stage
    printf 'Shelllist recovery failed; inspect its user units.\n' >&2
  fi
else
  session_result='no active graphical session'
fi

if ((switch_status != 0)); then
  rebuild_stage=$failed_stage
  exit "$switch_status"
fi
if ((stack_status != 0)); then
  rebuild_stage=$failed_stage
  exit "$stack_status"
fi

# Keep the deployment lock through approval. The updater takes only its state
# lock for this command. Pass the captured identity explicitly, not via global
# systemd environment or a mutable shared request file.
stage 'Recording the update baseline'
if /run/wrappers/bin/sudo "$approval_helper" approve-current "$snapshot_dir/baseline.json"; then
  baseline_result=recorded
else
  baseline_result='not approved (see reason above; deployment succeeded)'
  printf 'Warning: deployment succeeded, but no new unattended-update baseline was approved.\n' >&2
fi
rebuild_stage=complete
