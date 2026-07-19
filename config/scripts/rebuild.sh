set -euo pipefail

flake_dir=/etc/nixos
flake_attr=@FLAKE_ATTR@

if [ "$#" -gt 0 ] && [[ $1 != -* ]]; then
  flake_attr=$1
  shift
fi

cd "$flake_dir"
mapfile -d '' -t untracked_nix < <(
  git ls-files --others --exclude-standard -z -- ':(glob)**/*.nix'
)
if (( ${#untracked_nix[@]} )); then
  printf 'Refusing to rebuild with untracked Nix files; Git flakes exclude them:\n' >&2
  printf '  %s\n' "${untracked_nix[@]}" >&2
  printf 'Run git add on these files, then rebuild again.\n' >&2
  exit 1
fi

nix flake check "$flake_dir"
sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr" "$@"
