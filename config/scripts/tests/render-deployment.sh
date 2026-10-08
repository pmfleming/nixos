# Test-only dependency injection; deployed scripts accept no helper/lock overrides.
set -euo pipefail
source_dir=${1:?source scripts directory required}
test_dir=${2:?test scripts directory required}
mkdir -p "$test_dir"
: > "$test_dir/deployment.lock"
for name in deployment-lock rebuild rollback prune-nixos-generations; do
  sed \
    -e "s|@DEPLOYMENT_LOCK_FILE@|$test_dir/deployment.lock|g" \
    -e "s|@DEPLOYMENT_LOCK_HELPER@|$test_dir/deployment-lock.sh|g" \
    "$source_dir/$name.sh" > "$test_dir/$name.sh"
done
