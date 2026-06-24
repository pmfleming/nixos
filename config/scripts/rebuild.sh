set -euo pipefail

flake_dir=/etc/nixos
flake_attr=${1:-thinkpad}

cd "$flake_dir"
nix flake check "$flake_dir" --no-build
sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr"
