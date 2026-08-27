set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export AI_TOOLS_LIB_ONLY=1
export AI_TOOLS_STATE_DIR="$test_root/state"

# shellcheck source=/dev/null
source "$script_path"

mkdir -p "$AI_TOOLS_STATE_DIR"
printf '%s\n' '{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "stable", "nixpkgs-unstable": "fast", "local": "local" } },
    "stable": { "locked": { "rev": "stable-a" } },
    "fast": { "locked": { "rev": "fast-a" } },
    "local": { "locked": { "rev": "local-a" } }
  },
  "root": "root",
  "version": 7
}' > "$test_root/base.lock"

jq '.nodes.fast.locked.rev = "fast-b"' "$test_root/base.lock" > "$test_root/fast.lock"
jq '.nodes.stable.locked.rev = "stable-b"' "$test_root/base.lock" > "$test_root/stable.lock"
jq '.nodes.local.locked.rev = "local-b"' "$test_root/base.lock" > "$test_root/local.lock"

non_fast_locks_match "$test_root/base.lock" "$test_root/fast.lock"
if non_fast_locks_match "$test_root/base.lock" "$test_root/stable.lock"; then
  printf 'A stable-input change was mistaken for an AI-only lock change.\n' >&2
  exit 1
fi
if non_fast_locks_match "$test_root/base.lock" "$test_root/local.lock"; then
  printf 'A local-input change was mistaken for an AI-only lock change.\n' >&2
  exit 1
fi

# Staleness checks are intentionally non-fatal even before the first update;
# notification delivery is best-effort when no desktop bus exists.
check_stale

printf 'AI-tools updater state tests passed\n'
