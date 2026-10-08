set -euo pipefail

scripts_dir=$1
driver=${2:?native test driver required}
configuration=${3:?native test configuration required}
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
bash "$scripts_dir/tests/render-deployment.sh" "$scripts_dir" "$test_root/scripts"
scripts_dir="$test_root/scripts"
export NIXOS_DEPLOYMENT_LOCK_HELPER="$scripts_dir/deployment-lock.sh"
export NIXOS_DEPLOYMENT_LOCK_FILE="$test_root/ignored.lock"
# shellcheck source=/dev/null
source "$NIXOS_DEPLOYMENT_LOCK_HELPER"

cp "$driver" "$test_root/worker"
chmod +x "$test_root/worker"
jq -n --arg root "$test_root" '{root:$root,role:"worker"}' > "$test_root/worker.effect.json"
jq --arg root "$test_root" --arg lock "$scripts_dir/deployment.lock" '
  .state_directory=($root+"/state") | .ai_state_directory=($root+"/ai") |
  .flake_directory=($root+"/flake") | .deployment_lock=$lock |
  .active_system=($root+"/active") | .system_profile=($root+"/profile")
' "$configuration" > "$test_root/config.json"

# Exercise the actual native lock ordering, with no old shell updater oracle.
acquire_deployment_lock
"$test_root/worker" run-delayed
[ "$(jq -r .phase "$test_root/state/jobs/system.json")" = skipped ]
[ ! -e "$test_root/state/approval.json" ]
[ ! -e "$test_root/profile" ]
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
# Approval must reach manifest verification while rebuild holds deployment.lock.
# An intentionally absent manifest prevents any approval/state publication.
if "$test_root/worker" approve-current "$test_root/missing-manifest"; then
  printf 'Native approval accepted an absent manifest.\n' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
[ "$(jq -r .phase "$test_root/state/jobs/system.json")" = verifying ]
[ ! -e "$test_root/state/approval.json" ]
release_deployment_lock

# A released lock is usable by another process; process exit releases it too.
bash -c 'source "$NIXOS_DEPLOYMENT_LOCK_HELPER"; acquire_deployment_lock'
acquire_deployment_lock
release_deployment_lock

# Missing provisioning is an error, not an unlocked deployment or a timer skip.
rm "$scripts_dir/deployment.lock"
if bash -c 'source "$NIXOS_DEPLOYMENT_LOCK_HELPER"; acquire_deployment_lock'; then
  printf 'A missing lock file was silently accepted.\n' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
printf 'deployment lock tests passed\n'
