set -euo pipefail

flake_dir=@CONFIG_DIRECTORY@
flake_attr=@FLAKE_ATTR@
configured_local_inputs=( @LOCAL_INPUTS@ )
shelllist_daemons=(
  app-daemon.service
  bar-daemon.service
  bt-daemon.service
  clip-daemon.service
  nm-daemon.service
)
shelllist_units=( "${shelllist_daemons[@]}" shelllist.service )

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

# Add newly declared inputs without advancing anything, then derive the local
# git input set from the lock itself. The configured list is also used by the
# automatic updater, so refuse to continue if the two sets ever drift apart.
nix flake lock "$flake_dir"
mapfile -t local_inputs < <(
  jq -r '
    .nodes as $nodes
    | $nodes.root.inputs
    | to_entries[]
    | select(.value | type == "string")
    | select($nodes[.value].original.type == "git")
    | select($nodes[.value].original.url | startswith("file:"))
    | .key
  ' "$flake_dir/flake.lock"
)

declare -A undiscovered_inputs=()
for input in "${configured_local_inputs[@]}"; do
  undiscovered_inputs["$input"]=1
done
for input in "${local_inputs[@]}"; do
  if [[ ! -v "undiscovered_inputs[$input]" ]]; then
    printf 'Local git input %q is missing from machine.localProjects.\n' "$input" >&2
    exit 1
  fi
  unset 'undiscovered_inputs[$input]'
done
if ((${#undiscovered_inputs[@]})); then
  printf 'Configured local input is not a root git+file input: %s\n' \
    "${!undiscovered_inputs[*]}" >&2
  exit 1
fi
if ((${#local_inputs[@]} == 0)); then
  printf 'No machine-local git flake inputs were discovered.\n' >&2
  exit 1
fi

printf 'Updating every machine-local git flake input: %s\n' "${local_inputs[*]}"
nix flake update "${local_inputs[@]}" --flake "$flake_dir"

nix flake check "$flake_dir"

# A failed Home Manager unit transaction can still leave the new generation
# linked while some graphical units are stopped. Preserve the switch status,
# but always run the Shelllist recovery below after switch-to-configuration.
switch_status=0
if /run/wrappers/bin/sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr" "$@"; then
  :
else
  switch_status=$?
  printf 'The generation switch failed; attempting Shelllist recovery.\n' >&2
fi

# If D-Bus has activated Shelllist's privileged helper, move that process to
# the new package too. An inactive helper remains D-Bus activated.
if /run/wrappers/bin/sudo systemctl --quiet is-active bar-battery-helper.service; then
  /run/wrappers/bin/sudo systemctl restart bar-battery-helper.service || true
fi

# Home Manager's sd-switch restarts only changed units. Force the whole
# Shelllist process graph onto the new generation even when a unit file itself
# did not change (for example, after only a followed local input advanced).
stack_status=0
if systemctl --user --quiet is-active graphical-session.target; then
  printf 'Restarting Shelllist and all of its local daemons...\n'
  if systemctl --user daemon-reload \
    && systemctl --user stop shelllist.service \
    && systemctl --user restart "${shelllist_daemons[@]}" \
    && systemctl --user start shelllist.service \
    && systemctl --user --quiet is-active "${shelllist_units[@]}"; then
    printf 'Shelllist stack is active on the new generation.\n'
  else
    stack_status=$?
    printf 'Shelllist recovery failed; inspect its user units.\n' >&2
  fi
else
  printf 'No active graphical user session; Shelllist will start fresh at next login.\n'
fi

if ((switch_status != 0)); then
  exit "$switch_status"
fi
if ((stack_status != 0)); then
  exit "$stack_status"
fi

# Approval is based on the exact committed configuration revision, resulting
# lock hash, and active system path. Local project commits may remain unpushed;
# only unrelated uncommitted files in /etc/nixos prevent unattended updates.
if /run/wrappers/bin/sudo systemctl start --wait nixos-update-approve-baseline.service; then
  printf 'Recorded this successful rebuild as the unattended-update baseline.\n'
else
  printf 'The rebuild succeeded, but unattended NixOS updates remain paused; inspect nixos-update-approve-baseline.service.\n' >&2
  /run/wrappers/bin/sudo systemctl reset-failed nixos-update-approve-baseline.service || true
fi
