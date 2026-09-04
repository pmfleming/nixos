set -euo pipefail
export GIT_OPTIONAL_LOCKS=0

flake_dir=${NIXOS_UPDATE_FLAKE_DIR:-/etc/nixos}
flake_attr=${NIXOS_UPDATE_FLAKE_ATTR:-@FLAKE_ATTR@}
state_dir=${NIXOS_UPDATE_STATE_DIR:-/var/lib/nixos-delayed-updates-v2}
late_input=nixpkgs-unstable
read -r -a manual_inputs <<< "${NIXOS_UPDATE_MANUAL_INPUTS:-@MANUAL_INPUTS@}"
delay_seconds=${NIXOS_UPDATE_DELAY_SECONDS:-$((3 * 24 * 60 * 60))}
check_seconds=${NIXOS_UPDATE_DELAYED_CHECK_SECONDS:-$((24 * 60 * 60))}
delayed_dir="$state_dir/delayed"
applied_lock_hash="$state_dir/applied-lock-hash"
approved_revision_file="$state_dir/approved-revision"
approved_system_file="$state_dir/approved-system"
transaction_dir="$state_dir/apply-transaction"
update_lock_acquired=0
temporary_dirs=()

git_at_flake() {
  git -c safe.directory="$flake_dir" -C "$flake_dir" "$@"
}

hash_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

active_system_path() {
  readlink -f "${NIXOS_UPDATE_ACTIVE_SYSTEM_LINK:-/run/current-system}" 2>/dev/null || true
}

make_temp_dir() {
  tmp_dir="$(mktemp -d)"
  temporary_dirs+=("$tmp_dir")
}

cleanup() {
  exit_status=$?
  trap - EXIT

  if ((exit_status != 0 && update_lock_acquired == 1)) && [ -d "$transaction_dir" ]; then
    if ! rollback_transaction; then
      printf 'Automatic rollback failed; the persistent transaction will be retried on the next updater run.\n' >&2
    fi
  fi
  if ((${#temporary_dirs[@]} > 0)); then
    rm -rf "${temporary_dirs[@]}"
  fi
  notify_waybar_updates
  exit "$exit_status"
}

notify_waybar_updates() {
  pkill "-RTMIN+8" -x '\.waybar-wrapped|waybar' >/dev/null 2>&1 || true
}

clear_ready() {
  rm -f \
    "$delayed_dir/ready-flake.lock" "$delayed_dir/ready-flake.lock.new" \
    "$delayed_dir/ready-revision" "$delayed_dir/ready-revision.new" \
    "$delayed_dir/ready-base-hash" "$delayed_dir/ready-base-hash.new" \
    "$delayed_dir/ready-created-at" "$delayed_dir/ready-created-at.new" \
    "$delayed_dir/auto-apply" "$delayed_dir/auto-apply.new" \
    "$delayed_dir/system" "$delayed_dir/system.new"
}

clear_delayed_queue() {
  rm -f \
    "$delayed_dir/queued-flake.lock" "$delayed_dir/queued-flake.lock.new" \
    "$delayed_dir/queued-base-flake.lock" "$delayed_dir/queued-base-flake.lock.new" \
    "$delayed_dir/queued-revision" "$delayed_dir/queued-revision.new" \
    "$delayed_dir/first-seen" "$delayed_dir/first-seen.new"
}

ready_is_complete() {
  test -f "$delayed_dir/ready-flake.lock" \
    && test -f "$delayed_dir/ready-revision" \
    && test -f "$delayed_dir/ready-base-hash" \
    && test -f "$delayed_dir/ready-created-at" \
    && test -L "$delayed_dir/system"
}

worktree_status() {
  git_at_flake status --porcelain=v1 --untracked-files=normal
}

baseline_lock_is_safe() {
  status="$(worktree_status)"
  if [ -z "$status" ]; then
    return 0
  fi

  if [ ! -f "$applied_lock_hash" ]; then
    return 1
  fi

  while IFS= read -r line; do
    if [ "${line:3}" != "flake.lock" ]; then
      return 1
    fi
  done <<< "$status"

  [ "$(hash_file "$flake_dir/flake.lock")" = "$(cat "$applied_lock_hash")" ]
}

require_safe_baseline() {
  if baseline_lock_is_safe; then
    return 0
  fi

  printf '%s has changes not produced by the updater; retaining candidates without applying them.\n' "$flake_dir" >&2
  worktree_status >&2
  return 1
}

write_approved_revision() {
  printf '%s\n' "$1" > "$approved_revision_file.new"
  chmod 0644 "$approved_revision_file.new"
  mv -f "$approved_revision_file.new" "$approved_revision_file"
}

write_approved_system() {
  printf '%s\n' "$1" > "$approved_system_file.new"
  chmod 0644 "$approved_system_file.new"
  mv -f "$approved_system_file.new" "$approved_system_file"
}

approve_current() {
  status="$(worktree_status)"
  while IFS= read -r line; do
    if [ -n "$line" ] && [ "${line:3}" != "flake.lock" ]; then
      printf 'The successful rebuild is not an unattended-update approval because %s has non-lock changes:\n%s\n' \
        "$flake_dir" "$status" >&2
      return 1
    fi
  done <<< "$status"

  current_system="$(active_system_path)"
  if [ -z "$current_system" ] || [ ! -x "$current_system/bin/switch-to-configuration" ]; then
    printf 'The active NixOS system cannot be recorded as an approved baseline.\n' >&2
    return 1
  fi

  write_approved_revision "$(git_at_flake rev-parse --verify HEAD)"
  write_approved_system "$current_system"
  write_applied_lock_hash
  clear_ready
  clear_delayed_queue
  rm -rf "$transaction_dir" "$transaction_dir.new"
  printf 'Approved revision, lock, and active system from the successful manual rebuild.\n'
}

require_approved_revision() {
  current_revision="$(git_at_flake rev-parse --verify HEAD)"
  approved_revision="$(cat "$approved_revision_file" 2>/dev/null || true)"
  approved_system="$(cat "$approved_system_file" 2>/dev/null || true)"
  active_system="$(active_system_path)"
  if [ "$current_revision" = "$approved_revision" ] \
    && [ -n "$approved_system" ] \
    && [ "$active_system" = "$approved_system" ]; then
    return 0
  fi

  # A lock-only commit after an automatic application is safe to approve: its
  # live lock is already recorded by root, and all other files still match the
  # last manually approved revision.
  if [[ "$approved_revision" =~ ^[0-9a-f]{40,64}$ ]] \
    && [ -n "$approved_system" ] \
    && [ "$active_system" = "$approved_system" ] \
    && [ -f "$applied_lock_hash" ] \
    && [ "$(hash_file "$flake_dir/flake.lock")" = "$(cat "$applied_lock_hash")" ] \
    && git_at_flake cat-file -e "$approved_revision^{commit}" \
    && git_at_flake diff --quiet "$approved_revision" "$current_revision" -- . ':(exclude)flake.lock' \
    && [ "$(git_at_flake show "$current_revision:flake.lock" | sha256sum | cut -d ' ' -f 1)" = \
      "$(hash_file "$flake_dir/flake.lock")" ]; then
    write_approved_revision "$current_revision"
    printf 'Approved lock-only revision %s after its automatic application.\n' "$current_revision"
    return 0
  fi

  printf '%s revision %s, active system, and lock do not match the last successful manual or automatic baseline.\n' \
    "$flake_dir" "$current_revision" >&2
  return 1
}

create_stage() {
  make_temp_dir
  staged_flake="$tmp_dir/flake"
  mkdir -p "$staged_flake"
  revision="$(git_at_flake rev-parse --verify HEAD)"
  git_at_flake archive --format=tar "$revision" | tar -xf - -C "$staged_flake"
  cp "$flake_dir/flake.lock" "$staged_flake/flake.lock"
}

lock_without_late_input() {
  jq --arg input "$late_input" '
    .nodes.root.inputs[$input] as $node
    | del(.nodes.root.inputs[$input])
    | if $node then del(.nodes[$node]) else . end
  ' "$1"
}

queued_baseline_matches() {
  make_temp_dir
  lock_without_late_input "$1" > "$tmp_dir/left.json"
  lock_without_late_input "$2" > "$tmp_dir/right.json"
  cmp -s "$tmp_dir/left.json" "$tmp_dir/right.json"
}

delayed_root_inputs() {
  manual_inputs_json="$(printf '%s\n' "${manual_inputs[@]}" | jq -R . | jq -s .)"
  jq -r --arg late "$late_input" --argjson manual "$manual_inputs_json" '
    .nodes.root.inputs | keys[] | select(. != $late and (. as $name | $manual | index($name) | not))
  ' "$1"
}

record_check() {
  date +%s > "$delayed_dir/last-check.new"
  mv -f "$delayed_dir/last-check.new" "$delayed_dir/last-check"
}

check_is_due() {
  now="$(date +%s)"
  checked="$(cat "$delayed_dir/last-check" 2>/dev/null || printf '0')"
  ! [[ "$checked" =~ ^[0-9]+$ ]] || ((now - checked >= check_seconds))
}

mark_auto_apply() {
  printf '%s\n' auto > "$delayed_dir/auto-apply.new"
  mv -f "$delayed_dir/auto-apply.new" "$delayed_dir/auto-apply"
}

build_ready() {
  candidate_lock=$1
  candidate_revision=$2
  base_hash=$3
  apply_mode=${4:-manual}

  cp "$candidate_lock" "$staged_flake/flake.lock"
  nix flake check "path:$staged_flake" --no-update-lock-file
  # Keep the stable out-link pathname registered as the indirect GC root. Nix
  # replaces it only after the complete system build succeeds.
  nix build \
    --out-link "$delayed_dir/system" \
    "path:$staged_flake#nixosConfigurations.$flake_attr.config.system.build.toplevel"

  cp "$candidate_lock" "$delayed_dir/ready-flake.lock.new"
  printf '%s\n' "$candidate_revision" > "$delayed_dir/ready-revision.new"
  printf '%s\n' "$base_hash" > "$delayed_dir/ready-base-hash.new"
  date +%s > "$delayed_dir/ready-created-at.new"
  chmod 0644 "$delayed_dir"/ready-*.new
  for file in flake.lock revision base-hash created-at; do
    mv -f "$delayed_dir/ready-$file.new" "$delayed_dir/ready-$file"
  done
  if [ "$apply_mode" = auto ]; then
    mark_auto_apply
  fi
  printf 'A checked and built delayed update is ready to apply.\n'
}

save_delayed_queue() {
  candidate_lock=$1
  base_lock=$2
  candidate_revision=$3
  now="$(date +%s)"

  cp "$candidate_lock" "$delayed_dir/queued-flake.lock.new"
  cp "$base_lock" "$delayed_dir/queued-base-flake.lock.new"
  printf '%s\n' "$candidate_revision" > "$delayed_dir/queued-revision.new"
  printf '%s\n' "$now" > "$delayed_dir/first-seen.new"
  chmod 0644 "$delayed_dir"/*.new
  mv -f "$delayed_dir/queued-flake.lock.new" "$delayed_dir/queued-flake.lock"
  mv -f "$delayed_dir/queued-base-flake.lock.new" "$delayed_dir/queued-base-flake.lock"
  mv -f "$delayed_dir/queued-revision.new" "$delayed_dir/queued-revision"
  mv -f "$delayed_dir/first-seen.new" "$delayed_dir/first-seen"
  printf 'Frozen a delayed candidate for %s seconds.\n' "$delay_seconds"
}

seed_delayed_queue() {
  create_stage
  base_lock="$tmp_dir/base-flake.lock"
  updated_lock="$tmp_dir/delayed-flake.lock"
  cp "$flake_dir/flake.lock" "$base_lock"
  mapfile -t update_inputs < <(delayed_root_inputs "$base_lock")

  if ((${#update_inputs[@]} == 0)); then
    clear_delayed_queue
    printf 'There are no delayed inputs.\n'
    return 0
  fi

  nix flake update "${update_inputs[@]}" \
    --flake "path:$staged_flake" \
    --output-lock-file "$updated_lock"

  if cmp -s "$base_lock" "$updated_lock"; then
    clear_delayed_queue
    printf 'All delayed inputs are up to date.\n'
    return 0
  fi

  save_delayed_queue "$updated_lock" "$base_lock" "$revision"
}

delayed_queue_is_complete() {
  test -f "$delayed_dir/queued-flake.lock" \
    && test -f "$delayed_dir/queued-base-flake.lock" \
    && test -f "$delayed_dir/queued-revision" \
    && test -f "$delayed_dir/first-seen"
}

check_delayed() {
  apply_mode=${1:-manual}
  if ! require_approved_revision || ! require_safe_baseline; then
    return 0
  fi

  current_revision="$(git_at_flake rev-parse --verify HEAD)"
  current_hash="$(hash_file "$flake_dir/flake.lock")"

  if ready_is_complete; then
    if [ "$(cat "$delayed_dir/ready-revision")" = "$current_revision" ] \
      && [ "$(cat "$delayed_dir/ready-base-hash")" = "$current_hash" ]; then
      if [ "$apply_mode" = auto ]; then
        mark_auto_apply
      fi
      record_check
      printf 'The delayed candidate is built and ready.\n'
      return 0
    fi
    clear_ready
  fi

  if ! delayed_queue_is_complete; then
    seed_delayed_queue
    record_check
    return 0
  fi

  if [ "$(cat "$delayed_dir/queued-revision")" != "$current_revision" ] \
    || ! queued_baseline_matches "$delayed_dir/queued-base-flake.lock" "$flake_dir/flake.lock"; then
    printf 'The delayed queue no longer matches the live configuration; reseeding it.\n'
    clear_ready
    clear_delayed_queue
    seed_delayed_queue
    record_check
    return 0
  fi

  first_seen="$(cat "$delayed_dir/first-seen")"
  now="$(date +%s)"
  if ! [[ "$first_seen" =~ ^[0-9]+$ ]] || ((now - first_seen < delay_seconds)); then
    record_check
    printf 'The frozen delayed candidate is still in quarantine.\n'
    return 0
  fi

  create_stage
  cp "$delayed_dir/queued-flake.lock" "$staged_flake/flake.lock"
  rebased_lock="$tmp_dir/rebased-flake.lock"
  nix flake update "$late_input" \
    --flake "path:$staged_flake" \
    --output-lock-file "$rebased_lock"

  clear_ready
  build_ready "$rebased_lock" "$revision" "$current_hash" "$apply_mode"
  record_check
}

install_live_lock() {
  source_lock=$1
  live_lock_new="$state_dir/live-flake.lock.new"
  cp "$source_lock" "$live_lock_new"
  chmod 0644 "$live_lock_new"
  chown --reference="$flake_dir" "$live_lock_new"

  if [ "$(stat -c %d "$live_lock_new")" != "$(stat -c %d "$flake_dir")" ]; then
    rm -f "$live_lock_new"
    printf 'The trusted updater state and %s must be on the same filesystem for atomic lock installation.\n' \
      "$flake_dir" >&2
    return 1
  fi
  mv --no-copy -Tf "$live_lock_new" "$flake_dir/flake.lock"
}

write_applied_lock_hash() {
  hash_file "$flake_dir/flake.lock" > "$applied_lock_hash.new"
  chmod 0644 "$applied_lock_hash.new"
  mv -f "$applied_lock_hash.new" "$applied_lock_hash"
}

verify_candidate_system() {
  candidate_system="$(readlink -f "$delayed_dir/system" 2>/dev/null || true)"

  create_stage
  cp "$delayed_dir/ready-flake.lock" "$staged_flake/flake.lock"
  build_output="$(
    nix build \
      --no-link \
      --print-out-paths \
      "path:$staged_flake#nixosConfigurations.$flake_attr.config.system.build.toplevel"
  )"
  mapfile -t verified_systems <<< "$build_output"
  if ((${#verified_systems[@]} != 1)); then
    printf 'The delayed candidate evaluation returned %s system paths instead of one.\n' \
      "${#verified_systems[@]}" >&2
    return 1
  fi

  expected_system="$(readlink -f "${verified_systems[0]}" 2>/dev/null || true)"
  if [ -z "$candidate_system" ] \
    || [ "$candidate_system" != "$expected_system" ] \
    || [ ! -x "$expected_system/bin/switch-to-configuration" ]; then
    printf 'The saved delayed system does not match the system evaluated from its lock file.\n' >&2
    return 1
  fi
}

write_transaction_phase() {
  printf '%s\n' "$1" > "$transaction_dir/phase.new"
  mv -f "$transaction_dir/phase.new" "$transaction_dir/phase"
}

begin_transaction() {
  candidate_system=$1
  candidate_lock=$2
  transaction_new="$transaction_dir.new"

  rm -rf "$transaction_new"
  mkdir -m 0700 "$transaction_new"
  cp "$flake_dir/flake.lock" "$transaction_new/original-flake.lock"
  if [ -f "$applied_lock_hash" ]; then
    cp "$applied_lock_hash" "$transaction_new/original-applied-lock-hash"
  else
    touch "$transaction_new/no-original-applied-lock-hash"
  fi
  printf '%s\n' "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)" \
    > "$transaction_new/original-system"
  printf '%s\n' "$candidate_system" > "$transaction_new/candidate-system"
  hash_file "$candidate_lock" > "$transaction_new/candidate-lock-hash"
  printf '%s\n' prepared > "$transaction_new/phase"
  chmod 0600 "$transaction_new"/*
  mv -T "$transaction_new" "$transaction_dir"
}

finish_transaction() {
  candidate_hash="$(cat "$transaction_dir/candidate-lock-hash")"
  if [ "$(hash_file "$flake_dir/flake.lock")" != "$candidate_hash" ]; then
    printf 'Cannot finalize the update because the installed lock does not match the transaction.\n' >&2
    return 1
  fi

  write_applied_lock_hash
  write_approved_revision "$(git_at_flake rev-parse --verify HEAD)"
  write_approved_system "$(cat "$transaction_dir/candidate-system")"
  clear_ready
  clear_delayed_queue
  rm -rf "$transaction_dir"
}

rollback_transaction() {
  if [ ! -d "$transaction_dir" ]; then
    return 0
  fi
  if [ ! -f "$transaction_dir/original-flake.lock" ] \
    || [ ! -f "$transaction_dir/original-system" ] \
    || [ ! -f "$transaction_dir/phase" ]; then
    printf 'The update transaction is incomplete and cannot be rolled back automatically.\n' >&2
    return 1
  fi

  phase="$(cat "$transaction_dir/phase")"
  original_system="$(cat "$transaction_dir/original-system")"
  profile_system="$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)"
  install_live_lock "$transaction_dir/original-flake.lock"

  if { [ "$phase" != prepared ] && [ "$phase" != lock-installed ]; } \
    || [ "$profile_system" != "$original_system" ]; then
    if [ -z "$original_system" ] \
      || [ ! -x "$original_system/bin/switch-to-configuration" ]; then
      printf 'The original system recorded in the update transaction is not switchable.\n' >&2
      return 1
    fi
    if ! nix-env --profile /nix/var/nix/profiles/system --set "$original_system"; then
      return 1
    fi
    if ! "$original_system/bin/switch-to-configuration" boot; then
      return 1
    fi
  fi

  if [ -f "$transaction_dir/original-applied-lock-hash" ]; then
    cp "$transaction_dir/original-applied-lock-hash" "$applied_lock_hash.new"
    chmod 0644 "$applied_lock_hash.new"
    mv -f "$applied_lock_hash.new" "$applied_lock_hash"
  elif [ -f "$transaction_dir/no-original-applied-lock-hash" ]; then
    rm -f "$applied_lock_hash" "$applied_lock_hash.new"
  else
    printf 'The transaction does not record the previous applied lock hash.\n' >&2
    return 1
  fi

  rm -rf "$transaction_dir"
  printf 'Restored the system and lock from the interrupted update transaction.\n' >&2
}

recover_transaction() {
  rm -rf "$transaction_dir.new"
  if [ ! -d "$transaction_dir" ]; then
    return 0
  fi
  if [ ! -f "$transaction_dir/phase" ] \
    || [ ! -f "$transaction_dir/candidate-system" ] \
    || [ ! -f "$transaction_dir/candidate-lock-hash" ]; then
    printf 'The persistent update transaction is incomplete; refusing to continue.\n' >&2
    return 1
  fi

  phase="$(cat "$transaction_dir/phase")"
  candidate_system="$(cat "$transaction_dir/candidate-system")"
  candidate_hash="$(cat "$transaction_dir/candidate-lock-hash")"
  active_system="$(readlink -f /run/current-system 2>/dev/null || true)"
  current_hash="$(hash_file "$flake_dir/flake.lock")"

  if [ "$phase" = switched ] \
    && [ "$active_system" = "$candidate_system" ] \
    && [ "$current_hash" = "$candidate_hash" ]; then
    finish_transaction
    printf 'Finalized an update transaction that completed before interruption.\n'
    return 0
  fi

  printf 'Recovering an interrupted NixOS update transaction.\n' >&2
  rollback_transaction
}

ready_matches_live_baseline() {
  if ! require_approved_revision; then
    printf 'The delayed candidate remains ready because the configuration revision is not approved.\n' >&2
    return 1
  fi
  if ! baseline_lock_is_safe; then
    printf 'The delayed candidate remains ready because %s has user changes.\n' "$flake_dir" >&2
    return 1
  fi

  revision="$(git_at_flake rev-parse --verify HEAD)"
  if [ "$(cat "$delayed_dir/ready-revision")" != "$revision" ]; then
    printf 'The delayed candidate was built from a different Git revision.\n' >&2
    return 1
  fi

  current_hash="$(hash_file "$flake_dir/flake.lock")"
  if [ "$(cat "$delayed_dir/ready-base-hash")" != "$current_hash" ]; then
    printf 'The delayed candidate has a stale lock-file baseline.\n' >&2
    return 1
  fi
}

apply_delayed() {
  apply_mode=${1:-manual}

  if ! ready_is_complete; then
    printf 'No complete delayed candidate is ready.\n'
    return 0
  fi
  if [ "$apply_mode" = auto ] && [ ! -f "$delayed_dir/auto-apply" ]; then
    printf 'The delayed candidate requires manual approval.\n'
    return 0
  fi
  if ! ready_matches_live_baseline; then
    return 0
  fi
  if ! verify_candidate_system; then
    clear_ready
    return 1
  fi

  # Candidate verification can take long enough for the checkout to change.
  # Revalidate at the transaction boundary before replacing any live state.
  if ! ready_matches_live_baseline; then
    printf 'The delayed candidate remains ready because the live baseline changed during verification.\n' >&2
    return 0
  fi

  begin_transaction "$expected_system" "$delayed_dir/ready-flake.lock"
  install_live_lock "$delayed_dir/ready-flake.lock"
  write_transaction_phase lock-installed

  if ! nix-env --profile /nix/var/nix/profiles/system --set "$expected_system"; then
    printf 'Installing the delayed system profile failed; restoring the previous system.\n' >&2
    rollback_transaction
    return 1
  fi
  write_transaction_phase profile-installed

  if ! "$expected_system/bin/switch-to-configuration" boot; then
    printf 'Staging the delayed system for boot failed; restoring the previous boot target.\n' >&2
    rollback_transaction
    return 1
  fi
  write_transaction_phase switched
  finish_transaction
  printf 'Installed the checked delayed update for the next boot; the active desktop was not switched.\n'
}

run_delayed() {
  check_delayed auto
  apply_delayed auto
}

catch_up_delayed() {
  if check_is_due; then
    run_delayed
  fi
}

main() {
  mkdir -p "$delayed_dir"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 9>"$state_dir/update.lock"
  if ! flock -n 9; then
    printf 'Another NixOS update operation is already running.\n' >&2
    # Timer collisions are harmless skips, but baseline approval must not
    # report success when nothing was recorded.
    if [ "${1:-catch-up-delayed}" = approve-current ]; then
      return 75
    fi
    return 0
  fi
  update_lock_acquired=1
  if [ "${1:-catch-up-delayed}" = approve-current ]; then
    approve_current
    return
  fi
  recover_transaction

  case "${1:-catch-up-delayed}" in
    check-delayed) check_delayed "${2:-manual}" ;;
    run-delayed) run_delayed ;;
    catch-up-delayed) catch_up_delayed ;;
    apply-delayed) apply_delayed manual ;;
    *)
      printf 'Usage: %s approve-current | check-delayed [auto|manual] | run-delayed | catch-up-delayed | apply-delayed\n' "$0" >&2
      return 2
      ;;
  esac
}

if [ "${NIXOS_UPDATE_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
