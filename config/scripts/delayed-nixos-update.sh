set -euo pipefail

flake_dir=/etc/nixos
flake_attr=thinkpad
delay_seconds=$((3 * 24 * 60 * 60))
state_dir=/var/lib/nixos-delayed-updates
candidate_lock="$state_dir/candidate-flake.lock"
first_seen_file="$state_dir/first-seen"
pending_switch_file="$state_dir/current-lock-needs-switch"
ready_file=/run/nixos-updates-available

# Keep fast-moving AI coding tools current without waiting for the
# normal delayed-update window used by the rest of the flake inputs.
immediate_inputs=(nixpkgs-unstable)
immediate_inputs_json='["nixpkgs-unstable"]'

strip_immediate_inputs() {
  jq --argjson inputs "$immediate_inputs_json" '
    reduce $inputs[] as $input (.;
      if .nodes.root.inputs[$input] then
        del(.nodes[.nodes.root.inputs[$input]])
        | del(.nodes.root.inputs[$input])
      else
        .
      end
    )
  ' "$1"
}

merge_immediate_inputs_from_current() {
  jq --argjson inputs "$immediate_inputs_json" -s '
    .[0] as $delayed | .[1] as $current |
    reduce $inputs[] as $input ($delayed;
      if $current.nodes.root.inputs[$input] then
        .nodes.root.inputs[$input] = $current.nodes.root.inputs[$input]
        | .nodes[$current.nodes.root.inputs[$input]] = $current.nodes[$current.nodes.root.inputs[$input]]
      else
        del(.nodes.root.inputs[$input])
      end
    )
  ' "$1" "$2"
}

switch_current_if_pending() {
  if [ -f "$pending_switch_file" ]; then
    if nixos-rebuild switch --flake "$flake_dir#$flake_attr"; then
      rm -f "$pending_switch_file"
    fi
  fi
}

install_lock() {
  # This service runs as root, so a plain cp would leave flake.lock
  # root-owned and break later user-level git operations in the checkout.
  # Match the flake directory's existing ownership instead.
  cp "$1" "$flake_dir/flake.lock"
  chown --reference="$flake_dir" "$flake_dir/flake.lock"
}

mkdir -p "$state_dir"
rm -f "$ready_file"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

immediate_lock="$tmp_dir/immediate-flake.lock"
if nix flake update "${immediate_inputs[@]}" --flake "$flake_dir" --output-lock-file "$immediate_lock" >/dev/null 2>&1; then
  if ! cmp -s "$flake_dir/flake.lock" "$immediate_lock"; then
    install_lock "$immediate_lock"
    touch "$pending_switch_file"
  fi
fi

if ! nix flake update --flake "$flake_dir" --output-lock-file "$tmp_dir/flake.lock" >/dev/null 2>&1; then
  switch_current_if_pending
  exit 0
fi

current_comparable="$tmp_dir/current-comparable-flake.lock"
updated_comparable="$tmp_dir/updated-comparable-flake.lock"
strip_immediate_inputs "$flake_dir/flake.lock" > "$current_comparable"
strip_immediate_inputs "$tmp_dir/flake.lock" > "$updated_comparable"

if cmp -s "$current_comparable" "$updated_comparable"; then
  rm -f "$candidate_lock" "$first_seen_file" "$ready_file"
  switch_current_if_pending
  exit 0
fi

now="$(date +%s)"

if [ -f "$candidate_lock" ]; then
  candidate_comparable="$tmp_dir/candidate-comparable-flake.lock"
  strip_immediate_inputs "$candidate_lock" > "$candidate_comparable"
fi

if [ ! -f "$candidate_lock" ] || ! cmp -s "$candidate_comparable" "$updated_comparable"; then
  cp "$tmp_dir/flake.lock" "$candidate_lock"
  printf '%s\n' "$now" > "$first_seen_file"
  switch_current_if_pending
  exit 0
fi

first_seen="$(cat "$first_seen_file" 2>/dev/null || printf '%s' "$now")"
age=$((now - first_seen))

if [ "$age" -lt "$delay_seconds" ]; then
  switch_current_if_pending
  exit 0
fi

merged_lock="$tmp_dir/merged-flake.lock"
merge_immediate_inputs_from_current "$candidate_lock" "$flake_dir/flake.lock" > "$merged_lock"

touch "$ready_file"
install_lock "$merged_lock"
touch "$pending_switch_file"

if nixos-rebuild switch --flake "$flake_dir#$flake_attr"; then
  rm -f "$candidate_lock" "$first_seen_file" "$pending_switch_file" "$ready_file"
fi
