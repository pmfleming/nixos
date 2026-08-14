set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export NIXOS_UPDATE_FLAKE_DIR="$test_root/flake"
export NIXOS_UPDATE_STATE_DIR="$test_root/state"
export NIXOS_UPDATE_LIB_ONLY=1

# shellcheck source=/dev/null
source "$script_path"

test_flake_dir=$NIXOS_UPDATE_FLAKE_DIR
test_fast_dir=$NIXOS_UPDATE_STATE_DIR/fast
test_delayed_dir=$NIXOS_UPDATE_STATE_DIR/delayed
test_applied_lock_hash=$NIXOS_UPDATE_STATE_DIR/applied-lock-hash
test_fast_input=nixpkgs-unstable
staged_flake=

mkdir -p "$test_flake_dir" "$test_fast_dir" "$test_delayed_dir"
git -C "$test_flake_dir" init -q
git -C "$test_flake_dir" config user.email updater-test@example.invalid
git -C "$test_flake_dir" config user.name updater-test

printf '%s\n' '{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "stable", "nixpkgs-unstable": "fast" } },
    "stable": { "locked": { "rev": "stable-a" } },
    "fast": { "locked": { "rev": "fast-a" } }
  },
  "root": "root",
  "version": 7
}' > "$test_flake_dir/flake.lock"
printf 'test\n' > "$test_flake_dir/README.md"
git -C "$test_flake_dir" add flake.lock README.md
git -C "$test_flake_dir" commit -qm initial

baseline_lock_is_safe
printf 'dirty\n' >> "$test_flake_dir/README.md"
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

# Restore a clean baseline and exercise the delayed queue. The mocked Nix
# command produces a newer delayed input during discovery and a newer fast
# input when the matured queue is rebased.
git -C "$test_flake_dir" restore flake.lock
rm -f "$test_applied_lock_hash"
mock_delayed_rev=stable-b
mock_fast_rev=fast-b
nix() {
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

# A ready candidate based on another lock must remain pending rather than being
# applied over the live lock.
mkdir -p "$test_fast_dir"
cp "$captured_ready" "$test_fast_dir/ready-flake.lock"
git -C "$test_flake_dir" rev-parse HEAD > "$test_fast_dir/ready-revision"
printf 'stale-baseline\n' > "$test_fast_dir/ready-base-hash"
date +%s > "$test_fast_dir/ready-created-at"
ln -s "$test_root/nonexistent-system" "$test_fast_dir/system"
apply_lane fast
[ "$(cat "$test_fast_dir/ready-base-hash")" = stale-baseline ]

printf 'delayed updater state tests passed\n'
