set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export NIXOS_UPDATE_FLAKE_DIR="$test_root/flake"
export NIXOS_UPDATE_STATE_DIR="$test_root/state"
export NIXOS_UPDATE_LIB_ONLY=1
export NIXOS_UPDATE_MANUAL_INPUTS=shelllist

# shellcheck source=/dev/null
source "$script_path"

test_flake_dir=$NIXOS_UPDATE_FLAKE_DIR
test_fast_dir=$NIXOS_UPDATE_STATE_DIR/fast
test_delayed_dir=$NIXOS_UPDATE_STATE_DIR/delayed
test_applied_lock_hash=$NIXOS_UPDATE_STATE_DIR/applied-lock-hash
test_approved_revision=$NIXOS_UPDATE_STATE_DIR/approved-revision
test_transaction_dir=$NIXOS_UPDATE_STATE_DIR/apply-transaction
test_fast_input=nixpkgs-unstable
staged_flake=

mkdir -p "$test_flake_dir" "$test_fast_dir" "$test_delayed_dir"
git -C "$test_flake_dir" init -q
git -C "$test_flake_dir" config user.email updater-test@example.invalid
git -C "$test_flake_dir" config user.name updater-test

printf '%s\n' '{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "stable", "nixpkgs-unstable": "fast", "shelllist": "shelllist" } },
    "stable": { "locked": { "rev": "stable-a" } },
    "fast": { "locked": { "rev": "fast-a" } },
    "shelllist": { "locked": { "rev": "shelllist-a" } }
  },
  "root": "root",
  "version": 7
}' > "$test_flake_dir/flake.lock"
printf 'test\n' > "$test_flake_dir/README.md"
git -C "$test_flake_dir" add flake.lock README.md
git -C "$test_flake_dir" commit -qm initial
git -C "$test_flake_dir" rev-parse HEAD > "$test_approved_revision"

require_approved_revision
mapfile -t automatic_delayed_inputs < <(delayed_root_inputs "$test_flake_dir/flake.lock")
[ "${automatic_delayed_inputs[*]}" = nixpkgs ]
baseline_lock_is_safe
printf 'unapproved\n' >> "$test_flake_dir/README.md"
git -C "$test_flake_dir" commit -qam unapproved
if require_approved_revision; then
  printf 'An unapproved configuration revision was accepted.\n' >&2
  exit 1
fi
git -C "$test_flake_dir" reset -q --hard HEAD^

printf 'dirty\n' >> "$test_flake_dir/README.md"
rm -f "$test_fast_dir/last-check"
check_fast manual
if [ -e "$test_fast_dir/last-check" ]; then
  printf 'A skipped unsafe check was recorded as successful.\n' >&2
  exit 1
fi
if baseline_lock_is_safe; then
  printf 'An unrelated dirty file was accepted.\n' >&2
  exit 1
fi
git -C "$test_flake_dir" restore README.md

jq '.nodes.fast.locked.rev = "fast-b"' "$test_flake_dir/flake.lock" > "$test_root/fast.lock"
jq '.nodes.stable.locked.rev = "stable-b"' "$test_flake_dir/flake.lock" > "$test_root/stable.lock"
lock_without_fast_input "$test_flake_dir/flake.lock" > "$test_root/base-projection"
lock_without_fast_input "$test_root/fast.lock" > "$test_root/fast-projection"
lock_without_fast_input "$test_root/stable.lock" > "$test_root/stable-projection"
cmp -s "$test_root/base-projection" "$test_root/fast-projection"
if cmp -s "$test_root/base-projection" "$test_root/stable-projection"; then
  printf 'A delayed-input change disappeared from the lock projection.\n' >&2
  exit 1
fi

cp "$test_root/fast.lock" "$test_flake_dir/flake.lock"
if baseline_lock_is_safe; then
  printf 'An unrecognized dirty lock was accepted.\n' >&2
  exit 1
fi
hash_file "$test_flake_dir/flake.lock" > "$test_applied_lock_hash"
baseline_lock_is_safe
git -C "$test_flake_dir" add flake.lock
git -C "$test_flake_dir" commit -qm lock-only
require_approved_revision
[ "$(cat "$test_approved_revision")" = "$(git -C "$test_flake_dir" rev-parse HEAD)" ]

# Restore a clean baseline and exercise the delayed queue. The mocked Nix
# command produces a newer delayed input during discovery and a newer fast
# input when the matured queue is rebased.
git -C "$test_flake_dir" restore flake.lock
rm -f "$test_applied_lock_hash"
mock_delayed_rev=stable-b
mock_fast_rev=fast-b
mock_verified_system=
nix() {
  if [ "${1:-}" = build ]; then
    if [ -z "$mock_verified_system" ]; then
      printf 'No mocked verified system was configured.\n' >&2
      return 1
    fi
    printf '%s\n' "$mock_verified_system"
    return 0
  fi
  if [ "${1:-}" = flake ] && [ "${2:-}" = check ]; then
    return 0
  fi

  output_lock=
  input=
  previous=
  for argument in "$@"; do
    if [ "$previous" = --output-lock-file ]; then
      output_lock=$argument
    fi
    if [ "$argument" = "$test_fast_input" ]; then
      input=$test_fast_input
    fi
    previous=$argument
  done

  if [ -z "$output_lock" ]; then
    printf 'The mocked Nix command did not receive an output lock.\n' >&2
    return 1
  fi

  if [ "$input" = "$test_fast_input" ]; then
    jq --arg rev "$mock_fast_rev" '.nodes.fast.locked.rev = $rev' \
      "$staged_flake/flake.lock" > "$output_lock"
  else
    jq --arg rev "$mock_delayed_rev" '.nodes.stable.locked.rev = $rev' \
      "$staged_flake/flake.lock" > "$output_lock"
  fi
}

mock_verified_system="$test_root/verified-system"
mkdir -p "$mock_verified_system/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_verified_system/bin/switch-to-configuration"
chmod +x "$mock_verified_system/bin/switch-to-configuration"
cp "$test_flake_dir/flake.lock" "$test_fast_dir/ready-flake.lock"
ln -s "$mock_verified_system" "$test_fast_dir/system"
verify_candidate_system fast
rm "$test_fast_dir/system"
ln -s "$test_root/wrong-system" "$test_fast_dir/system"
if verify_candidate_system fast; then
  printf 'A saved system that differed from the evaluated candidate was accepted.\n' >&2
  exit 1
fi
clear_ready fast

seed_delayed_queue
queued_hash="$(hash_file "$test_delayed_dir/queued-flake.lock")"
first_seen="$(cat "$test_delayed_dir/first-seen")"
mock_delayed_rev=stable-c
check_delayed
[ "$(hash_file "$test_delayed_dir/queued-flake.lock")" = "$queued_hash" ]
[ "$(cat "$test_delayed_dir/first-seen")" = "$first_seen" ]

captured_ready=$test_root/captured-ready.lock
build_ready() {
  cp "$2" "$captured_ready"
  printf '%s\n' "$3" > "$test_root/captured-revision"
  printf '%s\n' "$4" > "$test_root/captured-base-hash"
}
delay_seconds=0
[ "$delay_seconds" -eq 0 ]
mock_fast_rev=fast-c
check_delayed
[ "$(jq -r '.nodes.stable.locked.rev' "$captured_ready")" = stable-b ]
[ "$(jq -r '.nodes.fast.locked.rev' "$captured_ready")" = fast-c ]
[ "$(cat "$test_root/captured-base-hash")" = "$(hash_file "$test_flake_dir/flake.lock")" ]

# A user edit made while the candidate is being independently verified must be
# noticed before the updater starts a transaction or replaces the live lock.
cp "$captured_ready" "$test_fast_dir/ready-flake.lock"
git -C "$test_flake_dir" rev-parse HEAD > "$test_fast_dir/ready-revision"
hash_file "$test_flake_dir/flake.lock" > "$test_fast_dir/ready-base-hash"
date +%s > "$test_fast_dir/ready-created-at"
ln -s "$mock_verified_system" "$test_fast_dir/system"
live_hash_before_verification="$(hash_file "$test_flake_dir/flake.lock")"
verify_candidate_system() {
  # Consumed by apply_lane in the sourced updater.
  # shellcheck disable=SC2034
  expected_system=$mock_verified_system
  printf 'concurrent user edit\n' >> "$test_flake_dir/README.md"
}
apply_lane fast manual
[ ! -d "$test_transaction_dir" ]
[ "$(hash_file "$test_flake_dir/flake.lock")" = "$live_hash_before_verification" ]
ready_is_complete fast
git -C "$test_flake_dir" restore README.md
clear_ready fast

# A ready candidate based on another lock must remain pending rather than being
# applied over the live lock.
mkdir -p "$test_fast_dir"
cp "$captured_ready" "$test_fast_dir/ready-flake.lock"
git -C "$test_flake_dir" rev-parse HEAD > "$test_fast_dir/ready-revision"
printf 'stale-baseline\n' > "$test_fast_dir/ready-base-hash"
date +%s > "$test_fast_dir/ready-created-at"
ln -s "$test_root/nonexistent-system" "$test_fast_dir/system"
apply_lane fast auto
[ "$(cat "$test_fast_dir/ready-base-hash")" = stale-baseline ]
mark_auto_apply fast
apply_lane fast auto
[ "$(cat "$test_fast_dir/ready-base-hash")" = stale-baseline ]

# A failed or interrupted application must restore both the lock and the
# previously trusted applied-lock hash.
git -C "$test_flake_dir" restore flake.lock
hash_file "$test_flake_dir/flake.lock" > "$test_applied_lock_hash"
original_applied_hash="$(cat "$test_applied_lock_hash")"
begin_transaction fast "$mock_verified_system" "$captured_ready"
install_live_lock "$captured_ready"
write_transaction_phase lock-installed
write_applied_lock_hash
rollback_transaction
[ "$(hash_file "$test_flake_dir/flake.lock")" = "$original_applied_hash" ]
[ "$(cat "$test_applied_lock_hash")" = "$original_applied_hash" ]
[ ! -d "$test_transaction_dir" ]

# A transaction marked switched is finalized after interruption only when the
# recorded candidate is the active system and its lock remains installed.
readlink_bin="$(command -v readlink)"
mock_active_system="$test_root/mock-active-system"
readlink() {
  if [ "${*: -1}" = /run/current-system ]; then
    printf '%s\n' "$mock_active_system"
  else
    "$readlink_bin" "$@"
  fi
}
begin_transaction fast "$mock_active_system" "$captured_ready"
install_live_lock "$captured_ready"
write_transaction_phase switched
recover_transaction
[ ! -d "$test_transaction_dir" ]
[ "$(cat "$test_applied_lock_hash")" = "$(hash_file "$test_flake_dir/flake.lock")" ]

printf 'delayed updater state tests passed\n'
