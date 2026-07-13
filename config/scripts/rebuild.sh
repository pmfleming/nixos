set -euo pipefail

flake_dir=/etc/nixos
flake_attr=thinkpad

if [ "$#" -gt 0 ] && [[ $1 != -* ]]; then
  flake_attr=$1
  shift
fi

cd "$flake_dir"
nix flake check "$flake_dir" --no-build
sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr" "$@"
