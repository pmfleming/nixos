set -euo pipefail

profile=/nix/var/nix/profiles/system
keep_recent=5
keep_every=10

refresh_boot_entries() {
  echo "Refreshing systemd-boot entries"
  /run/current-system/bin/switch-to-configuration boot
}

mapfile -t gens < <(
  nix-env --profile "$profile" --list-generations \
    | awk '{print $1}' \
    | sort -n
)

total="${#gens[@]}"
if (( total <= keep_recent )); then
  echo "Keeping all $total NixOS generations"
  refresh_boot_entries
  exit 0
fi

profile_current="$(readlink -f "$profile" 2>/dev/null || true)"
run_current="$(readlink -f /run/current-system 2>/dev/null || true)"
run_booted="$(readlink -f /run/booted-system 2>/dev/null || true)"

keep=()
delete=()

for idx in "${!gens[@]}"; do
  gen="${gens[$idx]}"
  link="$(readlink -f "$profile-$gen-link" 2>/dev/null || true)"
  keep_gen=0

  # Keep newest N generations.
  if (( idx >= total - keep_recent )); then
    keep_gen=1
  fi

  # Keep generation 1 and every 10th generation: 10, 20, 30, ...
  if (( gen == 1 || gen % keep_every == 0 )); then
    keep_gen=1
  fi

  # Never delete the current or booted system, even if it falls outside the policy.
  if [[ -n "$link" && -n "$profile_current" && "$link" == "$profile_current" ]]; then
    keep_gen=1
  fi
  if [[ -n "$link" && -n "$run_current" && "$link" == "$run_current" ]]; then
    keep_gen=1
  fi
  if [[ -n "$link" && -n "$run_booted" && "$link" == "$run_booted" ]]; then
    keep_gen=1
  fi

  if (( keep_gen )); then
    keep+=("$gen")
  else
    delete+=("$gen")
  fi
done

echo "Keeping NixOS generations: ${keep[*]}"

if (( ${#delete[@]} )); then
  echo "Deleting NixOS generations: ${delete[*]}"
  nix-env --profile "$profile" --delete-generations "${delete[@]}"
  nix-store --gc
else
  echo "No NixOS generations to delete"
fi

refresh_boot_entries
