set -Eeuo pipefail

flake_dir=@CONFIG_DIRECTORY@
flake_attr=@FLAKE_ATTR@
configured_local_inputs=( @LOCAL_INPUTS@ )

# Preserve complete output even when Nix's terminal UI disappears or the
# rebuild is interrupted. A process-substitution redirect keeps command exit
# statuses intact, unlike piping the whole script through tee.
state_home=${XDG_STATE_HOME:-${HOME:?HOME is not set}/.local/state}
log_dir="$state_home/nixos-rebuild"
umask 077
mkdir -p "$log_dir"
find "$log_dir" -maxdepth 1 -type f -name 'rebuild-*.log' -mtime +30 -delete
log_file="$log_dir/rebuild-$(date --utc +%Y%m%dT%H%M%SZ)-$$.running.log"
: > "$log_file"
ln -sfn "$(basename "$log_file")" "$log_dir/latest.log"
exec > >(tee -a "$log_file") 2>&1

rebuild_stage="initialization"
finish_log() {
  status=$?
  trap - EXIT HUP INT TERM
  set +e

  if ((status == 0)); then
    outcome=success
  else
    outcome=failed
  fi
  final_log=${log_file%.running.log}.$outcome.log
  if mv -- "$log_file" "$final_log"; then
    log_file=$final_log
  fi
  ln -sfn "$(basename "$log_file")" "$log_dir/latest.log"
  if ((status != 0)); then
    ln -sfn "$(basename "$log_file")" "$log_dir/latest-failed.log"
    printf '\nRebuild failed during %s (exit status %d).\n' "$rebuild_stage" "$status"
  else
    printf '\nRebuild completed successfully.\n'
  fi
  printf 'Log: %s\n' "$log_file"
  exit "$status"
}
trap finish_log EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Rebuild started at %s\n' "$(date --iso-8601=seconds)"
printf 'Log: %s\n' "$log_file"
printf 'Arguments:'
printf ' %q' "$@"
printf '\n'

shelllist_daemons=(
  app-daemon.service
  bar-daemon.service
  bt-daemon.service
  clip-daemon.service
  nm-daemon.service
)
shelllist_units=( "${shelllist_daemons[@]}" shelllist.service )

rebuild_stage="checking the configuration worktree"
cd "$flake_dir"
mapfile -d '' -t untracked_nix < <(
  git ls-files --others --exclude-standard -z -- ':(glob)**/*.nix'
)
if ((${#untracked_nix[@]})); then
  printf 'Refusing to rebuild with Nix files that Git flakes cannot see:\n' >&2
  printf '  %s\n' "${untracked_nix[@]}" >&2
  printf 'Add the files to Git before rebuilding.\n' >&2
  exit 1
fi

# Add newly declared inputs without advancing anything, then derive the local
# git input set from the lock itself. The configured list is also used by the
# automatic updater, so refuse to continue if the two sets ever drift apart.
rebuild_stage="locking flake inputs"
nix flake lock "$flake_dir"
rebuild_stage="validating machine-local flake inputs"
mapfile -t local_inputs < <(
  jq -r '
    .nodes as $nodes
    | $nodes.root.inputs
    | to_entries[]
    | select(.value | type == "string")
    | select($nodes[.value].original.type == "git")
    | select($nodes[.value].original.url | startswith("file:"))
    | .key
  ' "$flake_dir/flake.lock"
)

declare -A undiscovered_inputs=()
for input in "${configured_local_inputs[@]}"; do
  undiscovered_inputs["$input"]=1
done
for input in "${local_inputs[@]}"; do
  if [[ ! -v "undiscovered_inputs[$input]" ]]; then
    printf 'Local git input %q is missing from machine.localProjects.\n' "$input" >&2
    exit 1
  fi
  unset 'undiscovered_inputs[$input]'
done
if ((${#undiscovered_inputs[@]})); then
  printf 'Configured local input is not a root git+file input: %s\n' \
    "${!undiscovered_inputs[*]}" >&2
  exit 1
fi
if ((${#local_inputs[@]} == 0)); then
  printf 'No machine-local git flake inputs were discovered.\n' >&2
  exit 1
fi

printf 'Updating every machine-local git flake input: %s\n' "${local_inputs[*]}"
rebuild_stage="updating machine-local flake inputs"
nix flake update "${local_inputs[@]}" --flake "$flake_dir"

rebuild_stage="running flake checks"
nix flake check --print-build-logs "$flake_dir"

# A failed Home Manager unit transaction can still leave the new generation
# linked while some graphical units are stopped. Preserve the switch status,
# but always run the Shelllist recovery below after switch-to-configuration.
switch_status=0
rebuild_stage="building and switching the NixOS generation"
if /run/wrappers/bin/sudo nixos-rebuild switch --print-build-logs --flake "$flake_dir#$flake_attr" "$@"; then
  :
else
  switch_status=$?
  failed_stage=$rebuild_stage
  printf 'The generation switch failed; attempting Shelllist recovery.\n' >&2
fi

# If D-Bus has activated Shelllist's privileged helper, move that process to
# the new package too. An inactive helper remains D-Bus activated.
rebuild_stage="recovering the Shelllist stack"
if /run/wrappers/bin/sudo systemctl --quiet is-active bar-battery-helper.service; then
  /run/wrappers/bin/sudo systemctl restart bar-battery-helper.service || true
fi

# Home Manager's sd-switch restarts only changed units. Force the whole
# Shelllist process graph onto the new generation even when a unit file itself
# did not change (for example, after only a followed local input advanced).
stack_status=0
if systemctl --user --quiet is-active graphical-session.target; then
  printf 'Restarting Shelllist and all of its local daemons...\n'
  if systemctl --user daemon-reload \
    && systemctl --user stop shelllist.service \
    && systemctl --user restart "${shelllist_daemons[@]}" \
    && systemctl --user start shelllist.service \
    && systemctl --user --quiet is-active "${shelllist_units[@]}"; then
    printf 'Shelllist stack is active on the new generation.\n'
  else
    stack_status=$?
    if [[ -z ${failed_stage:-} ]]; then
      failed_stage=$rebuild_stage
    fi
    printf 'Shelllist recovery failed; inspect its user units.\n' >&2
  fi
else
  printf 'No active graphical user session; Shelllist will start fresh at next login.\n'
fi

if ((switch_status != 0)); then
  rebuild_stage=$failed_stage
  exit "$switch_status"
fi
if ((stack_status != 0)); then
  rebuild_stage=$failed_stage
  exit "$stack_status"
fi

# Approval is based on the exact committed configuration revision, resulting
# lock hash, and active system path. Local project commits may remain unpushed;
# only unrelated uncommitted files in /etc/nixos prevent unattended updates.
rebuild_stage="recording the unattended-update baseline"
if /run/wrappers/bin/sudo systemctl start --wait nixos-update-approve-baseline.service; then
  printf 'Recorded this successful rebuild as the unattended-update baseline.\n'
else
  printf 'The rebuild succeeded, but unattended NixOS updates remain paused; inspect nixos-update-approve-baseline.service.\n' >&2
  /run/wrappers/bin/sudo systemctl reset-failed nixos-update-approve-baseline.service || true
fi
