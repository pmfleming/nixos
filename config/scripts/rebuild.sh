set -euo pipefail

# shellcheck source=/dev/null
source "@DEPLOYMENT_LOCK_HELPER@"

flake_dir=@CONFIG_DIRECTORY@
source_state_helper=@SOURCE_STATE_HELPER@
approval_helper=@APPROVAL_HELPER@
report_helper=@REPORT_HELPER@
# Fail closed: nixos-rebuild has aliases and deployment modes that bypass our
# checked snapshot. Only accept build tuning, never arbitrary Nix options.
build_arguments=()
baseline_policy=warn
source_detail=()
live_output=false
monitor_output=false
parse_build_arguments() {
  # Bound both levels of parallelism: two derivations must not each spawn all
  # sixteen hardware threads. Explicit command-line values still win.
  local argument value max_jobs=2 build_cores=8

  while (($#)); do
    argument=$1
    shift
    case "$argument" in
      --require-baseline|--skip-baseline)
        if [[ $baseline_policy != warn ]]; then
          printf 'Choose only one baseline policy flag.\n' >&2
          return 2
        fi
        baseline_policy=${argument#--}
        ;;
      --show-source-files) source_detail=( --files ) ;;
      --monitor) monitor_output=true ;;
      --verbose|-v|--quiet|--print-build-logs|-L|--show-trace|--keep-going|-k|--keep-failed|-K|--fallback|--repair|--offline)
        build_arguments+=( "$argument" )
        case "$argument" in --verbose|-v|--print-build-logs|-L) live_output=true ;; esac
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
        if [[ $argument == --max-jobs ]]; then
          max_jobs=$value
        else
          build_cores=$value
        fi
        ;;
      *)
        printf 'rebuild owns source selection and local deployment; unsupported argument: %s\n' "$argument" >&2
        printf 'Supported: --require-baseline, --skip-baseline, --show-source-files, --monitor, -v, --quiet, -L, --show-trace, -k, -K, --fallback, --repair, --offline, -j/--max-jobs N|auto, --cores N.\n' >&2
        return 2
        ;;
    esac
  done
  build_arguments+=( --max-jobs "$max_jobs" --cores "$build_cores" )
}
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
stage_file="$log_file.stages"
run_record="$log_file.run.json"
python3 "$report_helper" start "$run_record" "$log_file" "$$" "$started_at" || \
  printf 'Warning: running rebuild status unavailable.\n'
: > "$stage_file"
monotonic_ticks() {
  local uptime _ignored
  read -r uptime _ignored < /proc/uptime
  printf '%s' "${uptime/./}"
}
stage_started=$(monotonic_ticks)
active_stage=initialization
stages_closed=false
deployed=false
system_before=$(readlink -f /run/current-system 2>/dev/null || true)
rebuild_stage=initialization
session_result='not reached'
baseline_result='not reached'
snapshot_dir=
cache_pending=
sudo_keepalive_pid=

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

closure_bytes() {
  local output size

  output=$(nix path-info --closure-size "$1" 2>/dev/null) || return 1
  size=${output##*[[:space:]]}
  [[ $size =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

run_logged() {
  if $live_output; then
    "$@"
  else
    "$@" >> "$log_file" 2>&1
  fi
}
run_build() {
  if $monitor_output; then
    "$@" 2>&1 | tee -a "$log_file" | nom >&3
  else
    run_logged "$@"
  fi
}

close_stage() {
  local now elapsed
  now=$(monotonic_ticks)
  elapsed=$((now - stage_started))
  jq -cn --arg name "$active_stage" --argjson ticks "$elapsed" \
    '{name:$name,seconds:($ticks / 100)}' >> "$stage_file"
  printf '    completed in %s\n' "$(human_duration "$((elapsed / 100))")"
  stage_started=$now
}

stage() {
  close_stage
  active_stage=$1
  rebuild_stage=$1
  printf '\n==> %s\n' "$rebuild_stage"
}

finish() {
  local status=$?
  local final_log system_after suffix=success

  trap - EXIT HUP INT TERM
  set +e
  # Stop the refresh loop before closing the logger or releasing any locks.
  if [[ -n $sudo_keepalive_pid ]]; then
    kill "$sudo_keepalive_pid" 2>/dev/null
    wait "$sudo_keepalive_pid" 2>/dev/null
  fi
  if ! $stages_closed; then close_stage; fi
  # Capture while still serialized; a later deploy must not become this run's
  # reported system merely because telemetry takes a moment to finish.
  system_after=$(readlink -f /run/current-system 2>/dev/null || true)
  release_deployment_lock
  [[ -z $snapshot_dir ]] || rm -rf -- "$snapshot_dir"
  [[ -z $cache_pending ]] || rm -rf -- "$cache_pending"

  # Close the pipe and wait for tee so every final build event is available to
  # the summary parser. Summary output is appended with a separate tee below.
  exec 1>&3 2>&4
  wait "$log_writer_pid"

  ((status == 0)) || suffix=failed
  final_log=${log_file%.running.log}.$suffix.log
  if mv -- "$log_file" "$final_log"; then
    log_file=$final_log
  fi
  ln -sfn "$(basename "$log_file")" "$log_dir/latest.log"
  if ((status != 0)); then
    ln -sfn "$(basename "$log_file")" "$log_dir/latest-failed.log"
  fi

  {
    jq -n --argjson started "$started_at" --argjson finished "$(date +%s)" \
      --argjson status "$status" --arg stage "$rebuild_stage" \
      --arg before "$system_before" --arg after "$system_after" --arg log "$log_file" \
      --arg baseline "$baseline_result" --arg session "$session_result" \
      --arg cb "$closure_before" --arg used "$store_used_before" --argjson deployed "$deployed" \
      '{started_at:$started,finished_at:$finished,exit_code:$status,
        failed_stage:(if $status == 0 then null else $stage end),system_before:$before,
        system_after:$after,log:$log,baseline:$baseline,session:$session,deployed:$deployed,
        closure_before:($cb|tonumber? // null),store_used_before:($used|tonumber? // null)}' | \
      python3 "$report_helper" "$stage_file" || \
        printf 'Warning: rebuild report unavailable; inspect %s (exit %d).\n' "$log_file" "$status"
    rm -f -- "$stage_file" "$run_record"

  } 2>&1 | tee -a "$log_file"

  exec 3>&- 4>&-
  exit "$status"
}

closure_before=
store_used_before=
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Rebuild started; full log: %s\n' "$log_file"
if (($#)); then
  printf 'nixos-rebuild arguments:'
  printf ' %q' "$@"
  printf '\n'
fi

stage 'Validating rebuild arguments'
parse_build_arguments "$@"

# Every invocation keeps its own log, including invalid arguments/contention.
# latest.log means latest attempt, not the owner of this lock.
stage 'Acquiring the interactive rebuild lock'
exec 9>"$log_dir/rebuild.lock"
if ! flock -n 9; then
  printf 'Another rebuild is already running. This log records only the rejected attempt.\n' >&2
  printf 'Inspect the other rebuild-*.running.log files in %s for the running build.\n' "$log_dir" >&2
  exit 75
fi

if [[ -n $system_before ]]; then
  closure_before=$(closure_bytes "$system_before") || closure_before=
fi
disk_before=$(df -B1 --output=used /nix/store 2>/dev/null | tail -n 1) || disk_before=
if [[ $disk_before =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
  store_used_before=${BASH_REMATCH[1]}
fi

stage 'Checking all local worktrees'
cd "$flake_dir"
preflight_json=$("$source_state_helper" source preflight "$flake_dir")
printf '%s\n' "$preflight_json" | jq . >> "$log_file"
printf 'Inspected %s local repositories.\n' "$(jq '.repositories | length' <<< "$preflight_json")"
if [[ $(jq -r '.baseline.eligible' <<< "$preflight_json") == false ]]; then
  printf 'Baseline preflight: configuration edits will prevent approval:\n'
  jq -r '.baseline | .repository, (.blockers[] | "  " + .)' <<< "$preflight_json"
  [[ $baseline_policy != require-baseline ]] || exit 1
fi
[[ $baseline_policy != skip-baseline ]] || printf 'Baseline approval explicitly skipped for this run.\n'
# The preflight above only discovers sources; authenticate before snapshot
# resolution, compatibility checks, and the expensive system build.
stage 'Authorizing the generation switch'
/run/wrappers/bin/sudo -v
# A build can outlive sudo's timestamp. Refresh silently and noninteractively;
# never retain the log pipe or lock descriptors in this background process.
(
  refresh_pid=
  trap '[[ -z $refresh_pid ]] || { kill "$refresh_pid" 2>/dev/null || true; wait "$refresh_pid" 2>/dev/null || true; }; exit 0' HUP INT TERM
  while kill -0 "$$" 2>/dev/null; do
    sleep 60 &
    refresh_pid=$!
    wait "$refresh_pid" || exit
    kill -0 "$$" 2>/dev/null || exit
    /run/wrappers/bin/sudo -n -v &
    refresh_pid=$!
    wait "$refresh_pid" || exit
  done
) </dev/null >/dev/null 2>&1 3>&- 4>&- 8<&- 9>&- &
sudo_keepalive_pid=$!

stage 'Acquiring the shared deployment lock'
acquire_deployment_lock

# CO-DEVELOPMENT INVARIANT: every daemon uses ONE current local framework.
# Include tracked uncommitted edits. Snapshot once so edits during a long check
# cannot change the graph subsequently deployed. Never persist local-project
# pins or replace this with flake update / --no-write-lock-file alone.
stage 'Snapshotting current local worktrees'
snapshot_dir=$(mktemp -d)
snapshot_json=$("$source_state_helper" source prepare \
  "$flake_dir" "$snapshot_dir/sources" "$snapshot_dir/baseline.json")
printf '%s\n' "$snapshot_json" > "$snapshot_dir/snapshot.json"
printf '%s\n' "$snapshot_json" | jq 'del(.sourceManifest)' >> "$log_file"
snapshot_flake=$(jq -er .flake <<< "$snapshot_json")
if [[ $(jq -r '.baseline.eligible' <<< "$snapshot_json") == false ]]; then
  printf 'Baseline capture: %s\n' "$(jq -r '.baseline.reason' <<< "$snapshot_json")"
  [[ $baseline_policy != require-baseline ]] || exit 1
fi
python3 "$report_helper" sources show "$snapshot_dir/snapshot.json" "$log_dir/last-sources.json" "$system_before" "${source_detail[@]}"

# Fail evaluation before scheduling release builds. --keep-going is opt-in,
# rather than spending minutes compiling after an already-fatal error.
stage 'Evaluating the frozen deployment graph'
run_logged nix flake check "$snapshot_flake" --no-update-lock-file --no-build "${build_arguments[@]}"

stage 'Running inexpensive deployment checks'
run_build nix build "$snapshot_flake#rebuildPreflight" --no-update-lock-file --no-link "${build_arguments[@]}"

stage 'Building the system and all deployment checks'
cache_dir="$state_home/nixos-rebuild/check-cache"
mkdir -p "$cache_dir"
# Recover abandoned attempts (e.g. SIGKILL). The interactive lock guarantees
# that none of these directories belongs to another running rebuild.
while IFS= read -r abandoned_cache; do
  [[ -f $abandoned_cache/complete ]] || rm -rf -- "$abandoned_cache"
done < <(find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -name 'entry-*')
cache_pending=$(mktemp -d "$cache_dir/entry-$(date --utc +%Y%m%dT%H%M%S%N)-XXXXXXXX")
# This aggregate contains EVERY checks.${system} derivation and the reusable
# Rust dependency artifacts. Nix registers the out-link as an indirect GC root.
run_build nix build "$snapshot_flake#rebuildDeployment" --no-update-lock-file \
  --out-link "$snapshot_dir/deployment" "${build_arguments[@]}"
system_path=$(readlink -f "$snapshot_dir/deployment/system")
checks_path=$(readlink -f "$snapshot_dir/deployment/checks")
[[ $system_path == /nix/store/* && -x $system_path/bin/switch-to-configuration ]]
[[ $checks_path == /nix/store/* ]]
# Preserve checks independently of the temporary deployment aggregate. This
# realizes an already-built store path, not another flake evaluation.
run_logged nix-store --add-root "$cache_pending/checks" --indirect --realise "$checks_path"
# Never move the link: Nix's indirect GC root records its absolute location.
# Failed attempts leave the previous two successful check sets intact.
touch "$cache_pending/complete"
cache_pending=
mapfile -t cache_entries < <(find "$cache_dir" -mindepth 2 -maxdepth 2 -type f -name complete -printf '%h\n' | sort -r)
declare -A retained_targets=()
retained_count=0
for cache_entry in "${cache_entries[@]}"; do
  cache_target=$(readlink -- "$cache_entry/checks")
  if [[ ${retained_targets[$cache_target]+present} ]] || ((retained_count >= 2)); then
    rm -rf -- "$cache_entry"
  else
    retained_targets["$cache_target"]=1
    retained_count=$((retained_count + 1))
  fi
done

# Activation can fail after Home Manager has stopped graphical services. Save
# the switch status, then make a best effort to put the complete stack back in
# a known state before returning that status.
switch_status=0
failed_stage=
stage 'Switching the checked NixOS generation'
if run_logged /run/wrappers/bin/sudo nixos-rebuild switch --store-path "$system_path" --no-reexec; then
  deployed=true
  python3 "$report_helper" sources save "$snapshot_dir/snapshot.json" "$log_dir/last-sources.json" \
    "$(readlink -f /run/current-system)" || printf 'Warning: deployed source history could not be saved.\n'
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
if [[ $baseline_policy == skip-baseline ]]; then
  baseline_result='skipped by request (previous approval unchanged)'
elif approval_output=$(/run/wrappers/bin/sudo "$approval_helper" approve-current "$snapshot_dir/baseline.json" 2>&1); then
  printf '%s\n' "$approval_output"
  baseline_result=recorded
else
  printf '%s\n' "$approval_output"
  baseline_result="not approved ($approval_output; deployment succeeded)"
  printf 'Warning: deployment succeeded, but no new unattended-update baseline was approved.\n' >&2
  [[ $baseline_policy != require-baseline ]] || exit 1
fi
close_stage
stages_closed=true
rebuild_stage=complete
