set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export NIXOS_UPDATE_FLAKE_DIR="$test_root/flake"
export NIXOS_UPDATE_STATE_DIR="$test_root/state"
export NIXOS_UPDATE_ACTIVE_SYSTEM_LINK="$test_root/active-system-link"
export NIXOS_UPDATE_LIB_ONLY=1
export NIXOS_UPDATE_MANUAL_INPUTS=shelllist

# shellcheck source=/dev/null
source "$script_path"

test_flake_dir=$NIXOS_UPDATE_FLAKE_DIR
test_delayed_dir=$NIXOS_UPDATE_STATE_DIR/delayed
test_applied_lock_hash=$NIXOS_UPDATE_STATE_DIR/applied-lock-hash
test_approved_revision=$NIXOS_UPDATE_STATE_DIR/approved-revision
test_approved_system=$NIXOS_UPDATE_STATE_DIR/approved-system
test_transaction_dir=$NIXOS_UPDATE_STATE_DIR/apply-transaction
test_late_input=nixpkgs-unstable
staged_flake=

mkdir -p "$test_flake_dir" "$test_delayed_dir" "$test_root/initial-system/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/initial-system/bin/switch-to-configuration"
chmod +x "$test_root/initial-system/bin/switch-to-configuration"
ln -s "$test_root/initial-system" "$NIXOS_UPDATE_ACTIVE_SYSTEM_LINK"
git -C "$test_flake_dir" init -q
git -C "$test_flake_dir" config user.email updater-test@example.invalid
git -C "$test_flake_dir" config user.name updater-test

printf '%s\n' '{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "stable", "nixpkgs-unstable": "late", "shelllist": "shelllist" } },
    "stable": { "locked": { "rev": "stable-a" } },
    "late": { "locked": { "rev": "late-a" } },
    "shelllist": { "locked": { "rev": "shelllist-a" } }
  },
  "root": "root",
  "version": 7
}' > "$test_flake_dir/flake.lock"
printf 'test\n' > "$test_flake_dir/README.md"
git -C "$test_flake_dir" add flake.lock README.md
git -C "$test_flake_dir" commit -qm initial
approve_current
[ "$(cat "$test_approved_revision")" = "$(git -C "$test_flake_dir" rev-parse HEAD)" ]
[ "$(cat "$test_approved_system")" = "$test_root/initial-system" ]
[ "$(cat "$test_applied_lock_hash")" = "$(hash_file "$test_flake_dir/flake.lock")" ]

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
rm -f "$test_delayed_dir/last-check"
check_delayed manual
if [ -e "$test_delayed_dir/last-check" ]; then
  printf 'A skipped unsafe check was recorded as successful.\n' >&2
  exit 1
fi
if baseline_lock_is_safe; then
  printf 'An unrelated dirty file was accepted.\n' >&2
  exit 1
fi
git -C "$test_flake_dir" restore README.md

jq '.nodes.late.locked.rev = "late-b"' "$test_flake_dir/flake.lock" > "$test_root/late.lock"
jq '.nodes.stable.locked.rev = "stable-b"' "$test_flake_dir/flake.lock" > "$test_root/stable.lock"
lock_without_late_input "$test_flake_dir/flake.lock" > "$test_root/base-projection"
lock_without_late_input "$test_root/late.lock" > "$test_root/late-projection"
lock_without_late_input "$test_root/stable.lock" > "$test_root/stable-projection"
cmp -s "$test_root/base-projection" "$test_root/late-projection"
if cmp -s "$test_root/base-projection" "$test_root/stable-projection"; then
  printf 'A delayed-input change disappeared from the lock projection.\n' >&2
  exit 1
fi

cp "$test_root/late.lock" "$test_flake_dir/flake.lock"
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

# Restore a clean baseline. The mock advances the delayed input during
# discovery and the independently managed input only after quarantine.
git -C "$test_flake_dir" restore flake.lock
rm -f "$test_applied_lock_hash"
mock_delayed_rev=stable-b
mock_late_rev=late-b
mock_verified_system=
nix() {
  if [ "${1:-}" = build ]; then
    [ -n "$mock_verified_system" ] || return 1
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
    if [ "$argument" = "$test_late_input" ]; then
      input=$test_late_input
    fi
    previous=$argument
  done
  [ -n "$output_lock" ] || return 1

  if [ "$input" = "$test_late_input" ]; then
    jq --arg rev "$mock_late_rev" '.nodes.late.locked.rev = $rev' \
      "$staged_flake/flake.lock" > "$output_lock"
  else
    jq --arg rev "$mock_delayed_rev" '.nodes.stable.locked.rev = $rev' \
      "$staged_flake/flake.lock" > "$output_lock"
  fi
}

mock_verified_system="$test_root/verified-system"
mkdir -p "$mock_verified_system/bin"
cat > "$mock_verified_system/bin/switch-to-configuration" <<EOF
#!$(command -v bash)
printf '%s\\n' "\$1" > "$test_root/switch-operation"
EOF
chmod +x "$mock_verified_system/bin/switch-to-configuration"
cp "$test_flake_dir/flake.lock" "$test_delayed_dir/ready-flake.lock"
ln -s "$mock_verified_system" "$test_delayed_dir/system"
verify_candidate_system
rm "$test_delayed_dir/system"
ln -s "$test_root/wrong-system" "$test_delayed_dir/system"
if verify_candidate_system; then
  printf 'A saved system that differed from the evaluated candidate was accepted.\n' >&2
  exit 1
fi
clear_ready

# Automatic application prepares the generation for boot without activating
# Home Manager or graphical units in the current session.
cp "$test_flake_dir/flake.lock" "$test_delayed_dir/ready-flake.lock"
git -C "$test_flake_dir" rev-parse HEAD > "$test_delayed_dir/ready-revision"
hash_file "$test_flake_dir/flake.lock" > "$test_delayed_dir/ready-base-hash"
date +%s > "$test_delayed_dir/ready-created-at"
ln -s "$mock_verified_system" "$test_delayed_dir/system"
nix-env() { return 0; }
apply_delayed manual
[ "$(cat "$test_root/switch-operation")" = boot ]
[ ! -d "$test_transaction_dir" ]
approve_current

seed_delayed_queue
queued_hash="$(hash_file "$test_delayed_dir/queued-flake.lock")"
first_seen="$(cat "$test_delayed_dir/first-seen")"
mock_delayed_rev=stable-c
check_delayed
[ "$(hash_file "$test_delayed_dir/queued-flake.lock")" = "$queued_hash" ]
[ "$(cat "$test_delayed_dir/first-seen")" = "$first_seen" ]

captured_ready=$test_root/captured-ready.lock
build_ready() {
  cp "$1" "$captured_ready"
  printf '%s\n' "$2" > "$test_root/captured-revision"
  printf '%s\n' "$3" > "$test_root/captured-base-hash"
}
delay_seconds=0
[ "$delay_seconds" -eq 0 ]
mock_late_rev=late-c
check_delayed
[ "$(jq -r '.nodes.stable.locked.rev' "$captured_ready")" = stable-b ]
[ "$(jq -r '.nodes.late.locked.rev' "$captured_ready")" = late-c ]
[ "$(cat "$test_root/captured-base-hash")" = "$(hash_file "$test_flake_dir/flake.lock")" ]

make_ready() {
  cp "$captured_ready" "$test_delayed_dir/ready-flake.lock"
  git -C "$test_flake_dir" rev-parse HEAD > "$test_delayed_dir/ready-revision"
  hash_file "$test_flake_dir/flake.lock" > "$test_delayed_dir/ready-base-hash"
  date +%s > "$test_delayed_dir/ready-created-at"
  ln -s "$mock_verified_system" "$test_delayed_dir/system"
}

# Revalidate after independent verification to catch concurrent user edits.
make_ready
live_hash_before_verification="$(hash_file "$test_flake_dir/flake.lock")"
verify_candidate_system() {
  # shellcheck disable=SC2034
  expected_system=$mock_verified_system
  printf 'concurrent user edit\n' >> "$test_flake_dir/README.md"
}
apply_delayed manual
[ ! -d "$test_transaction_dir" ]
[ "$(hash_file "$test_flake_dir/flake.lock")" = "$live_hash_before_verification" ]
ready_is_complete
git -C "$test_flake_dir" restore README.md
clear_ready

# Stale and non-auto candidates remain pending.
make_ready
printf 'stale-baseline\n' > "$test_delayed_dir/ready-base-hash"
apply_delayed auto
[ "$(cat "$test_delayed_dir/ready-base-hash")" = stale-baseline ]
mark_auto_apply
apply_delayed auto
[ "$(cat "$test_delayed_dir/ready-base-hash")" = stale-baseline ]
clear_ready

# Rollback restores both the live lock and its trusted hash.
git -C "$test_flake_dir" restore flake.lock
hash_file "$test_flake_dir/flake.lock" > "$test_applied_lock_hash"
original_applied_hash="$(cat "$test_applied_lock_hash")"
begin_transaction "$mock_verified_system" "$captured_ready"
install_live_lock "$captured_ready"
write_transaction_phase lock-installed
write_applied_lock_hash
rollback_transaction
[ "$(hash_file "$test_flake_dir/flake.lock")" = "$original_applied_hash" ]
[ "$(cat "$test_applied_lock_hash")" = "$original_applied_hash" ]
[ ! -d "$test_transaction_dir" ]

# Recover a transaction interrupted after switching.
readlink_bin="$(command -v readlink)"
mock_active_system="$test_root/mock-active-system"
readlink() {
  if [ "${*: -1}" = /run/current-system ]; then
    printf '%s\n' "$mock_active_system"
  else
    "$readlink_bin" "$@"
  fi
}
begin_transaction "$mock_active_system" "$captured_ready"
install_live_lock "$captured_ready"
write_transaction_phase switched
recover_transaction
[ ! -d "$test_transaction_dir" ]
[ "$(cat "$test_applied_lock_hash")" = "$(hash_file "$test_flake_dir/flake.lock")" ]

# Catch-up runs only when the daily check is overdue.
catchup_runs=0
run_delayed() { catchup_runs=$((catchup_runs + 1)); }
rm -f "$test_delayed_dir/last-check"
catch_up_delayed
[ "$catchup_runs" -eq 1 ]
date +%s > "$test_delayed_dir/last-check"
catch_up_delayed
[ "$catchup_runs" -eq 1 ]

printf 'delayed updater state tests passed\n'
