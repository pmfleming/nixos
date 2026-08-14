set -euo pipefail
export GIT_OPTIONAL_LOCKS=0

flake_dir=${NIXOS_UPDATE_FLAKE_DIR:-/etc/nixos}
flake_attr=${NIXOS_UPDATE_FLAKE_ATTR:-@FLAKE_ATTR@}
state_dir=${NIXOS_UPDATE_STATE_DIR:-/var/lib/nixos-delayed-updates}
fast_input=nixpkgs-unstable
delay_seconds=${NIXOS_UPDATE_DELAY_SECONDS:-$((3 * 24 * 60 * 60))}
fast_check_seconds=${NIXOS_UPDATE_FAST_CHECK_SECONDS:-$((6 * 60 * 60))}
delayed_check_seconds=${NIXOS_UPDATE_DELAYED_CHECK_SECONDS:-$((24 * 60 * 60))}
fast_dir="$state_dir/fast"
delayed_dir="$state_dir/delayed"
applied_lock_hash="$state_dir/applied-lock-hash"
temporary_dirs=()

git_at_flake() {
  git -c safe.directory="$flake_dir" -C "$flake_dir" "$@"
}

hash_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

make_temp_dir() {
  tmp_dir="$(mktemp -d)"
  temporary_dirs+=("$tmp_dir")
}

cleanup() {
  if ((${#temporary_dirs[@]} > 0)); then
    rm -rf "${temporary_dirs[@]}"
  fi
  notify_waybar_updates
}

notify_waybar_updates() {
  pkill "-RTMIN+8" -x '\.waybar-wrapped|waybar' >/dev/null 2>&1 || true
}

archive_legacy_state() {
  legacy_dir="$state_dir/legacy-single-lane-state"
  legacy_files=(
    candidate-flake.lock
    current-lock-needs-switch
    first-seen
    ready-flake.lock
    ready-revision
    ready-scope
    system
  )
  for legacy_file in "${legacy_files[@]}"; do
    if [ -e "$state_dir/$legacy_file" ] || [ -L "$state_dir/$legacy_file" ]; then
      mkdir -p "$legacy_dir"
      mv -f "$state_dir/$legacy_file" "$legacy_dir/$legacy_file"
    fi
  done
}

lane_dir() {
  case "$1" in
    fast) printf '%s\n' "$fast_dir" ;;
    delayed) printf '%s\n' "$delayed_dir" ;;
    *)
      printf 'Unknown update lane: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

clear_ready() {
  target_dir="$(lane_dir "$1")"
  rm -f \
    "$target_dir/ready-flake.lock" "$target_dir/ready-flake.lock.new" \
    "$target_dir/ready-revision" "$target_dir/ready-revision.new" \
    "$target_dir/ready-base-hash" "$target_dir/ready-base-hash.new" \
    "$target_dir/ready-created-at" "$target_dir/ready-created-at.new" \
    "$target_dir/system" "$target_dir/system.new"
}

clear_delayed_queue() {
  rm -f \
    "$delayed_dir/queued-flake.lock" "$delayed_dir/queued-flake.lock.new" \
    "$delayed_dir/queued-base-flake.lock" "$delayed_dir/queued-base-flake.lock.new" \
    "$delayed_dir/queued-revision" "$delayed_dir/queued-revision.new" \
    "$delayed_dir/first-seen" "$delayed_dir/first-seen.new"
}

ready_is_complete() {
  target_dir="$(lane_dir "$1")"
  test -f "$target_dir/ready-flake.lock" \
    && test -f "$target_dir/ready-revision" \
    && test -f "$target_dir/ready-base-hash" \
    && test -f "$target_dir/ready-created-at" \
    && test -L "$target_dir/system"
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

create_stage() {
  make_temp_dir
  staged_flake="$tmp_dir/flake"
  mkdir -p "$staged_flake"
  revision="$(git_at_flake rev-parse --verify HEAD)"
  git_at_flake archive --format=tar "$revision" | tar -xf - -C "$staged_flake"
  cp "$flake_dir/flake.lock" "$staged_flake/flake.lock"
}

lock_without_fast_input() {
  jq --arg input "$fast_input" '
    .nodes.root.inputs[$input] as $node
    | del(.nodes.root.inputs[$input])
    | if $node then del(.nodes[$node]) else . end
  ' "$1"
}

non_fast_locks_match() {
  make_temp_dir
  lock_without_fast_input "$1" > "$tmp_dir/left.json"
  lock_without_fast_input "$2" > "$tmp_dir/right.json"
  cmp -s "$tmp_dir/left.json" "$tmp_dir/right.json"
}

delayed_root_inputs() {
  jq -r --arg fast "$fast_input" '
    .nodes.root.inputs | keys[] | select(. != $fast)
  ' "$1"
}

record_check() {
  target_dir="$(lane_dir "$1")"
  date +%s > "$target_dir/last-check.new"
  mv -f "$target_dir/last-check.new" "$target_dir/last-check"
}

check_is_due() {
  lane=$1
  interval=$2
  target_dir="$(lane_dir "$lane")"
  now="$(date +%s)"
  checked="$(cat "$target_dir/last-check" 2>/dev/null || printf '0')"
  ! [[ "$checked" =~ ^[0-9]+$ ]] || ((now - checked >= interval))
}

build_ready() {
  lane=$1
  candidate_lock=$2
  candidate_revision=$3
  base_hash=$4
  target_dir="$(lane_dir "$lane")"

  cp "$candidate_lock" "$staged_flake/flake.lock"
  nix flake check "path:$staged_flake" --no-update-lock-file
  rm -f "$target_dir/system.new"
  nix build \
    --out-link "$target_dir/system.new" \
    "path:$staged_flake#nixosConfigurations.$flake_attr.config.system.build.toplevel"

  cp "$candidate_lock" "$target_dir/ready-flake.lock.new"
  printf '%s\n' "$candidate_revision" > "$target_dir/ready-revision.new"
  printf '%s\n' "$base_hash" > "$target_dir/ready-base-hash.new"
  date +%s > "$target_dir/ready-created-at.new"
  chmod 0644 \
    "$target_dir/ready-flake.lock.new" \
    "$target_dir/ready-revision.new" \
    "$target_dir/ready-base-hash.new" \
    "$target_dir/ready-created-at.new"
  mv -Tf "$target_dir/system.new" "$target_dir/system"
  mv -f "$target_dir/ready-flake.lock.new" "$target_dir/ready-flake.lock"
  mv -f "$target_dir/ready-revision.new" "$target_dir/ready-revision"
  mv -f "$target_dir/ready-base-hash.new" "$target_dir/ready-base-hash"
  mv -f "$target_dir/ready-created-at.new" "$target_dir/ready-created-at"
  printf 'A checked and built %s-lane update is ready to apply.\n' "$lane"
}

check_fast() {
  if ! require_safe_baseline; then
    record_check fast
    return 0
  fi

  create_stage
  base_hash="$(hash_file "$flake_dir/flake.lock")"
  updated_lock="$tmp_dir/fast-flake.lock"
  nix flake update "$fast_input" \
    --flake "path:$staged_flake" \
    --output-lock-file "$updated_lock"

  if cmp -s "$flake_dir/flake.lock" "$updated_lock"; then
    clear_ready fast
    record_check fast
    printf 'Codex, Pi, and Claude are up to date.\n'
    return 0
  fi

  if ready_is_complete fast \
    && [ "$(cat "$fast_dir/ready-revision")" = "$revision" ] \
    && [ "$(cat "$fast_dir/ready-base-hash")" = "$base_hash" ] \
    && cmp -s "$fast_dir/ready-flake.lock" "$updated_lock"; then
    record_check fast
    printf 'The existing fast-lane candidate is still current.\n'
    return 0
  fi

  clear_ready fast
  build_ready fast "$updated_lock" "$revision" "$base_hash"
  record_check fast
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
  printf 'Frozen a delayed-lane candidate for %s seconds.\n' "$delay_seconds"
}

seed_delayed_queue() {
  create_stage
  base_lock="$tmp_dir/base-flake.lock"
  updated_lock="$tmp_dir/delayed-flake.lock"
  cp "$flake_dir/flake.lock" "$base_lock"
  mapfile -t update_inputs < <(delayed_root_inputs "$base_lock")

  if ((${#update_inputs[@]} == 0)); then
    clear_delayed_queue
    printf 'There are no delayed-lane inputs.\n'
    return 0
  fi

  nix flake update "${update_inputs[@]}" \
    --flake "path:$staged_flake" \
    --output-lock-file "$updated_lock"

  if cmp -s "$base_lock" "$updated_lock"; then
    clear_delayed_queue
    printf 'All delayed-lane inputs are up to date.\n'
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
  if ! require_safe_baseline; then
    record_check delayed
    return 0
  fi

  current_revision="$(git_at_flake rev-parse --verify HEAD)"
  current_hash="$(hash_file "$flake_dir/flake.lock")"

  if ready_is_complete delayed; then
    if [ "$(cat "$delayed_dir/ready-revision")" = "$current_revision" ] \
      && [ "$(cat "$delayed_dir/ready-base-hash")" = "$current_hash" ]; then
      record_check delayed
      printf 'The delayed-lane candidate is built and ready.\n'
      return 0
    fi
    clear_ready delayed
  fi

  if ! delayed_queue_is_complete; then
    seed_delayed_queue
    record_check delayed
    return 0
  fi

  if [ "$(cat "$delayed_dir/queued-revision")" != "$current_revision" ] \
    || ! non_fast_locks_match "$delayed_dir/queued-base-flake.lock" "$flake_dir/flake.lock"; then
    printf 'The delayed queue no longer matches the live configuration; reseeding it.\n'
    clear_ready delayed
    clear_delayed_queue
    seed_delayed_queue
    record_check delayed
    return 0
  fi

  first_seen="$(cat "$delayed_dir/first-seen")"
  now="$(date +%s)"
  if ! [[ "$first_seen" =~ ^[0-9]+$ ]] || ((now - first_seen < delay_seconds)); then
    record_check delayed
    printf 'The frozen delayed-lane candidate is still in quarantine.\n'
    return 0
  fi

  create_stage
  cp "$delayed_dir/queued-flake.lock" "$staged_flake/flake.lock"
  rebased_lock="$tmp_dir/rebased-flake.lock"
  nix flake update "$fast_input" \
    --flake "path:$staged_flake" \
    --output-lock-file "$rebased_lock"

  clear_ready delayed
  build_ready delayed "$rebased_lock" "$revision" "$current_hash"
  record_check delayed
}

worktree_allows_apply() {
  baseline_lock_is_safe
}

restore_previous_system() {
  original_lock=$1
  original_system=$2
  cp "$original_lock" "$flake_dir/flake.lock"
  chown --reference="$flake_dir" "$flake_dir/flake.lock"
  if [ -n "$original_system" ] && [ -x "$original_system/bin/switch-to-configuration" ]; then
    nix-env --profile /nix/var/nix/profiles/system --set "$original_system" || true
    "$original_system/bin/switch-to-configuration" switch || true
  fi
}

apply_lane() {
  lane=$1
  target_dir="$(lane_dir "$lane")"

  if ! ready_is_complete "$lane"; then
    printf 'No complete %s-lane candidate is ready.\n' "$lane"
    return 0
  fi

  if ! worktree_allows_apply; then
    printf 'The %s-lane candidate remains ready because %s has user changes.\n' "$lane" "$flake_dir" >&2
    return 0
  fi

  revision="$(git_at_flake rev-parse --verify HEAD)"
  if [ "$(cat "$target_dir/ready-revision")" != "$revision" ]; then
    printf 'The %s-lane candidate was built from a different Git revision.\n' "$lane" >&2
    return 0
  fi

  current_hash="$(hash_file "$flake_dir/flake.lock")"
  if [ "$(cat "$target_dir/ready-base-hash")" != "$current_hash" ]; then
    printf 'The %s-lane candidate has a stale lock-file baseline.\n' "$lane" >&2
    return 0
  fi

  candidate_system="$(readlink -f "$target_dir/system")"
  if [ ! -x "$candidate_system/bin/switch-to-configuration" ]; then
    printf 'The %s-lane candidate does not contain a switchable NixOS system.\n' "$lane" >&2
    clear_ready "$lane"
    return 1
  fi

  make_temp_dir
  original_lock="$tmp_dir/original-flake.lock"
  cp "$flake_dir/flake.lock" "$original_lock"
  original_system="$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)"

  cp "$target_dir/ready-flake.lock" "$flake_dir/flake.lock"
  chown --reference="$flake_dir" "$flake_dir/flake.lock"

  if ! nix-env --profile /nix/var/nix/profiles/system --set "$candidate_system" \
    || ! "$candidate_system/bin/switch-to-configuration" switch; then
    printf 'Applying the %s-lane candidate failed; restoring the previous system.\n' "$lane" >&2
    restore_previous_system "$original_lock" "$original_system"
    return 1
  fi

  hash_file "$flake_dir/flake.lock" > "$applied_lock_hash.new"
  mv -f "$applied_lock_hash.new" "$applied_lock_hash"
  clear_ready "$lane"
  if [ "$lane" = delayed ]; then
    clear_delayed_queue
  fi

  other_lane=delayed
  if [ "$lane" = delayed ]; then
    other_lane=fast
  fi
  clear_ready "$other_lane"
  printf 'Applied the checked %s-lane update successfully.\n' "$lane"
}

catch_up() {
  if check_is_due fast "$fast_check_seconds"; then
    check_fast
  fi
  if check_is_due delayed "$delayed_check_seconds"; then
    check_delayed
  fi
}

apply_ready() {
  apply_lane fast
  apply_lane delayed
}

main() {
  mkdir -p "$fast_dir" "$delayed_dir"
  trap cleanup EXIT
  exec 9>"$state_dir/update.lock"
  if ! flock -n 9; then
    printf 'Another NixOS update operation is already running.\n' >&2
    return 0
  fi
  archive_legacy_state

  case "${1:-catch-up}" in
    check-fast) check_fast ;;
    check-delayed) check_delayed ;;
    catch-up) catch_up ;;
    apply-fast) apply_lane fast ;;
    apply-delayed) apply_lane delayed ;;
    apply-ready) apply_ready ;;
    *)
      printf 'Usage: %s check-fast | check-delayed | catch-up | apply-fast | apply-delayed | apply-ready\n' "$0" >&2
      return 2
      ;;
  esac
}

if [ "${NIXOS_UPDATE_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
