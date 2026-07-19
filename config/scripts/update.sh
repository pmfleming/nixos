set -euo pipefail

flake_dir=/etc/nixos
flake_attr=${1:-@FLAKE_ATTR@}

# Intentional escape hatch: unlike delayed-nixos-update, this updates and
# switches immediately. The resulting dirty flake.lock must be reviewed and
# committed (or reverted) before a staged update can be approved.
cd "$flake_dir"
printf 'Running a direct update; commit or revert flake.lock afterward to re-enable approvals.\n' >&2
nix flake update
exec rebuild "$flake_attr"
