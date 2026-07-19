set -euo pipefail
export GIT_OPTIONAL_LOCKS=0

flake_dir=/etc/nixos
flake_ref="git+file://$flake_dir"
flake_attr=@FLAKE_ATTR@
state_dir=/var/lib/nixos-delayed-updates
ready_lock="$state_dir/ready-flake.lock"
ready_revision="$state_dir/ready-revision"
ready_scope="$state_dir/ready-scope"
result_link="$state_dir/system"
last_full_check="$state_dir/last-full-check"
last_catchup_attempt="$state_dir/last-catchup-attempt"
catchup_retry_seconds=$((60 * 60))

git_at_flake() {
  git -c safe.directory="$flake_dir" -C "$flake_dir" "$@"
}

configure_scope() {
  scope="$1"
  case "$scope" in
    all)
      update_inputs=()
      scope_label="all flake inputs"
      ;;
    apps)
      # Codex, Pi, and Claude are all sourced from nixpkgs-unstable.
      update_inputs=(nixpkgs-unstable)
      scope_label="Codex, Pi, and Claude"
      ;;
    *)
      printf 'Unknown update scope: %s\n' "$scope" >&2
      return 2
      ;;
  esac
}

notify_waybar_updates() {
  # The waybar custom/updates module is signal-driven (RTMIN+8) instead of
  # polling; tell it to re-check the persistent ready state.
  pkill "-RTMIN+8" -x '\.waybar-wrapped|waybar' >/dev/null 2>&1 || true
}

worktree_is_clean() {
  status="$({
    git_at_flake status --porcelain=v1 --untracked-files=normal
  })"

  if [ -n "$status" ]; then
    printf '%s has uncommitted changes.\n' "$flake_dir" >&2
    printf '%s\n' "$status" >&2
    return 1
  fi
}

stage_committed_worktree() {
  mkdir -p "$staged_flake"
  git_at_flake archive --format=tar "$revision" \
    | tar -xf - -C "$staged_flake"
}

clear_ready_update() {
  rm -f \
    "$ready_lock" "$ready_lock.new" \
    "$ready_revision" "$ready_revision.new" \
    "$ready_scope" "$ready_scope.new" \
    "$result_link" "$result_link.new"
}

record_full_check_success() {
  if [ "$scope" = all ]; then
    date +%s > "$last_full_check.new"
    mv -f "$last_full_check.new" "$last_full_check"
    rm -f "$last_catchup_attempt"
  fi
}

check_for_update() {
  configure_scope "$1" || return

  # Checks always archive the committed HEAD, so uncommitted work can remain in
  # place without being evaluated or modified. Approval still requires a clean
  # checkout at this exact revision.
  tmp_dir="$(mktemp -d)"
  staged_flake="$tmp_dir/flake"
  updated_lock="$tmp_dir/flake.lock"
  revision="$(git_at_flake rev-parse --verify HEAD)"
  trap 'rm -rf "$tmp_dir"; notify_waybar_updates' EXIT

  stage_committed_worktree
  nix flake update "${update_inputs[@]}" \
    --flake "path:$staged_flake" \
    --output-lock-file "$updated_lock"

  if cmp -s "$staged_flake/flake.lock" "$updated_lock"; then
    clear_ready_update
    record_full_check_success
    printf '%s are up to date.\n' "$scope_label"
    return 0
  fi

  if [ -f "$ready_lock" ] \
    && [ -f "$ready_revision" ] \
    && [ -f "$ready_scope" ] \
    && [ -L "$result_link" ] \
    && [ "$(cat "$ready_revision")" = "$revision" ] \
    && cmp -s "$ready_lock" "$updated_lock"; then
    printf '%s\n' "$scope" > "$ready_scope"
    record_full_check_success
    printf 'The previously built %s update is still awaiting approval.\n' "$scope_label"
    return 0
  fi

  cp "$updated_lock" "$staged_flake/flake.lock"
  nix flake check "path:$staged_flake" --no-update-lock-file

  rm -f "$result_link.new"
  nix build \
    --out-link "$result_link.new" \
    "path:$staged_flake#nixosConfigurations.$flake_attr.config.system.build.toplevel"

  cp "$updated_lock" "$ready_lock.new"
  printf '%s\n' "$revision" > "$ready_revision.new"
  printf '%s\n' "$scope" > "$ready_scope.new"
  chmod 0644 "$ready_lock.new"
  chmod 0644 "$ready_revision.new"
  chmod 0644 "$ready_scope.new"
  mv -Tf "$result_link.new" "$result_link"
  mv -f "$ready_lock.new" "$ready_lock"
  mv -f "$ready_revision.new" "$ready_revision"
  mv -f "$ready_scope.new" "$ready_scope"
  record_full_check_success

  printf 'A checked and built %s update is ready for manual approval.\n' "$scope_label"
  printf 'Review: diff -u %s/flake.lock %s\n' "$flake_dir" "$ready_lock"
  printf 'Apply:  systemctl start nixos-update-approve.service\n'
}

catch_up_if_overdue() {
  now="$(date +%s)"
  overnight_cutoff="$(date --date='today 03:00' +%s)"
  if (( now < overnight_cutoff )); then
    overnight_cutoff="$(date --date='yesterday 03:00' +%s)"
  fi

  completed="$(cat "$last_full_check" 2>/dev/null || printf '0')"
  if [[ "$completed" =~ ^[0-9]+$ ]] && (( completed >= overnight_cutoff )); then
    return 0
  fi

  attempted="$(cat "$last_catchup_attempt" 2>/dev/null || printf '0')"
  if [[ "$attempted" =~ ^[0-9]+$ ]] && (( now - attempted < catchup_retry_seconds )); then
    return 0
  fi

  printf '%s\n' "$now" > "$last_catchup_attempt.new"
  mv -f "$last_catchup_attempt.new" "$last_catchup_attempt"
  printf 'The latest overnight NixOS update check was missed; starting an AC-power catch-up.\n'
  check_for_update all
}

approve_update() {
  if [ ! -f "$ready_lock" ] || [ ! -f "$ready_revision" ] || [ ! -f "$ready_scope" ]; then
    clear_ready_update
    notify_waybar_updates
    printf 'No checked NixOS update is awaiting approval.\n'
    return 0
  fi

  if ! worktree_is_clean; then
    printf 'Commit or discard the local changes before approving the update.\n' >&2
    return 1
  fi

  revision="$(git_at_flake rev-parse --verify HEAD)"
  if [ "$(cat "$ready_revision")" != "$revision" ]; then
    printf 'The checked update was built for a different Git revision. Run the update check again.\n' >&2
    return 1
  fi

  if ! configure_scope "$(cat "$ready_scope")"; then
    printf 'The checked update has an invalid scope.\n' >&2
    return 1
  fi

  tmp_dir="$(mktemp -d)"
  original_lock="$tmp_dir/flake.lock"
  cp "$flake_dir/flake.lock" "$original_lock"
  lock_installed=false

  restore_lock_on_failure() {
    exit_status=$?
    if [ "$exit_status" -ne 0 ] && [ "$lock_installed" = true ]; then
      cp "$original_lock" "$flake_dir/flake.lock"
      chown --reference="$flake_dir" "$flake_dir/flake.lock"
      printf 'Approval failed; restored the original flake.lock.\n' >&2
    fi
    rm -rf "$tmp_dir"
    notify_waybar_updates
    exit "$exit_status"
  }
  trap restore_lock_on_failure EXIT

  cp "$ready_lock" "$flake_dir/flake.lock"
  chown --reference="$flake_dir" "$flake_dir/flake.lock"
  lock_installed=true

  # Recheck the exact live configuration and candidate lock immediately before
  # the explicitly approved deployment.
  nix flake check "$flake_ref" --no-update-lock-file
  nixos-rebuild switch --flake "$flake_ref#$flake_attr"

  lock_installed=false
  clear_ready_update
  printf 'The approved %s update has been switched successfully.\n' "$scope_label"
}

mkdir -p "$state_dir"
exec 9>"$state_dir/update.lock"
if ! flock -n 9; then
  printf 'Another NixOS update operation is already running.\n' >&2
  exit 1
fi

case "${1:-check}" in
  check)
    check_for_update "${2:-all}"
    ;;
  catch-up)
    catch_up_if_overdue
    ;;
  approve)
    approve_update
    ;;
  *)
    printf 'Usage: %s check [all|apps] | catch-up | approve\n' "$0" >&2
    exit 2
    ;;
esac
