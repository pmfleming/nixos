# Shared by the interactive rebuild, unattended staging, and generation pruning.
# The inode is created by tmpfiles, never by a caller: replacing a lock file
# would allow two processes to believe they own the same deployment lock.
deployment_lock_held=0

acquire_deployment_lock() {
  local lock_file="${NIXOS_DEPLOYMENT_LOCK_FILE:-@DEPLOYMENT_LOCK_FILE@}"

  if ! { exec 8< "$lock_file"; }; then
    printf 'Cannot open deployment lock %s; activate the tmpfiles configuration first.\n' "$lock_file" >&2
    return 1
  fi
  if ! flock -n 8; then
    exec 8<&-
    printf 'Another NixOS deployment or generation-pruning operation is running.\n' >&2
    return 75
  fi
  deployment_lock_held=1
}

release_deployment_lock() {
  if (( deployment_lock_held )); then
    flock -u 8
    exec 8<&-
    deployment_lock_held=0
  fi
}
