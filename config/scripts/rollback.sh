# shellcheck source=/dev/null
source "${NIXOS_DEPLOYMENT_LOCK_HELPER:-@DEPLOYMENT_LOCK_HELPER@}"
/run/wrappers/bin/sudo -v
acquire_deployment_lock
trap release_deployment_lock EXIT
/run/wrappers/bin/sudo nixos-rebuild switch --rollback
