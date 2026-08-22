set -euo pipefail

flake_dir=@CONFIG_DIRECTORY@
flake_attr=@FLAKE_ATTR@
local_inputs=( @LOCAL_INPUTS@ )

cd "$flake_dir"
mapfile -d '' -t untracked_nix < <(
  git ls-files --others --exclude-standard -z -- ':(glob)**/*.nix'
)
if ((${#untracked_nix[@]})); then
  printf 'Refusing to rebuild with Nix files that Git flakes cannot see:\n' >&2
  printf '  %s\n' "${untracked_nix[@]}" >&2
  printf 'Add the files to Git before rebuilding.\n' >&2
  exit 1
fi

printf 'Updating machine-local flake inputs: %s\n' "${local_inputs[*]}"
nix flake update "${local_inputs[@]}" --flake "$flake_dir"

nix flake check "$flake_dir"
/run/wrappers/bin/sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr" "$@"
