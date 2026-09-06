set -euo pipefail

scripts_dir=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export NIXOS_DEPLOYMENT_LOCK_HELPER="$scripts_dir/deployment-lock.sh"
export NIXOS_DEPLOYMENT_LOCK_FILE="$test_root/deployment.lock"
export NIXOS_UPDATE_STATE_DIR="$test_root/state"
: > "$NIXOS_DEPLOYMENT_LOCK_FILE"
# shellcheck source=/dev/null
source "$NIXOS_DEPLOYMENT_LOCK_HELPER"

# Model rebuild holding the shared lock. Timer jobs must skip before touching
# either the updater state or the system profile, not wait and deadlock.
acquire_deployment_lock
bash "$scripts_dir/delayed-nixos-update.sh" run-delayed
[ ! -e "$NIXOS_UPDATE_STATE_DIR" ]
if bash "$scripts_dir/prune-nixos-generations.sh" --profile "$test_root/missing-profile"; then
  printf 'Pruning ignored deployment lock contention.\n' >&2
  exit 1
else
  [ "$?" -eq 75 ]
fi
if bash -c 'source "$NIXOS_DEPLOYMENT_LOCK_HELPER"; acquire_deployment_lock'; then
  printf 'A second interactive deployment acquired the lock.\n' >&2
  exit 1
else
  [ "$?" -eq 75 ]
fi

# Approval must be able to run while rebuild holds the deployment lock. Stub
# only the approval work; keep the actual main() lock ordering and cleanup.
bash -c '
  export NIXOS_UPDATE_LIB_ONLY=1
  source "$1/delayed-nixos-update.sh"
  approve_current() { touch "$NIXOS_UPDATE_STATE_DIR/approved"; }
  notify_waybar_updates() { :; }
  main approve-current
' bash "$scripts_dir"
[ -f "$NIXOS_UPDATE_STATE_DIR/approved" ]
release_deployment_lock

# A released lock is usable by another process; process exit releases it too.
bash -c 'source "$NIXOS_DEPLOYMENT_LOCK_HELPER"; acquire_deployment_lock'
acquire_deployment_lock
release_deployment_lock

# Missing provisioning is an error, not an unlocked deployment or a timer skip.
rm "$NIXOS_DEPLOYMENT_LOCK_FILE"
if bash -c 'source "$NIXOS_DEPLOYMENT_LOCK_HELPER"; acquire_deployment_lock'; then
  printf 'A missing lock file was silently accepted.\n' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
printf 'deployment lock tests passed\n'
