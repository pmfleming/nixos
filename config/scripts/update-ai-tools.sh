set -euo pipefail

flake_dir=${AI_TOOLS_FLAKE_DIR:-/etc/nixos}
state_dir=${AI_TOOLS_STATE_DIR:-/var/lib/nixos-ai-tools}
fast_input=nixpkgs-unstable
notify_user=${AI_TOOLS_NOTIFY_USER:-@USERNAME@}
stale_seconds=${AI_TOOLS_STALE_SECONDS:-$((4 * 60 * 60))}
notify_interval=${AI_TOOLS_NOTIFY_INTERVAL:-$((6 * 60 * 60))}
temporary_dir=
operation=${1:-update}

git_at_flake() {
  git -c safe.directory="$flake_dir" -C "$flake_dir" "$@"
}

require_runtime_commands() {
  local command
  local -a missing=()

  for command in \
    cat chmod cmp cp date env flock git id jq mkdir mktemp mv nix \
    notify-send pkill readlink rm runuser tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
      missing+=("$command")
    fi
  done

  if ((${#missing[@]})); then
    printf 'Missing runtime commands: %s\n' "${missing[*]}" >&2
    return 1
  fi
}

lock_without_fast_input() {
  jq --arg input "$fast_input" '
    .nodes.root.inputs[$input] as $node
    | del(.nodes.root.inputs[$input])
    | if $node then del(.nodes[$node]) else . end
  ' "$1"
}

non_fast_locks_match() {
  left="$(mktemp)"
  right="$(mktemp)"
  lock_without_fast_input "$1" > "$left"
  lock_without_fast_input "$2" > "$right"
  cmp -s "$left" "$right"
  status=$?
  rm -f "$left" "$right"
  return "$status"
}

notify_desktop() {
  summary=$1
  body=$2
  notify_uid="$(id -u "$notify_user" 2>/dev/null || true)"
  bus="/run/user/$notify_uid/bus"
  if [ -n "$notify_uid" ] && [ -S "$bus" ]; then
    runuser -u "$notify_user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      notify-send --urgency=critical --app-name=nixos-ai-tools "$summary" "$body" \
      >/dev/null 2>&1 || true
  fi
}

notification_is_due() {
  marker=$1
  now="$(date +%s)"
  previous="$(cat "$marker" 2>/dev/null || printf '0')"
  ! [[ "$previous" =~ ^[0-9]+$ ]] || ((now - previous >= notify_interval))
}

record_notification() {
  marker=$1
  date +%s > "$marker.new"
  mv -f "$marker.new" "$marker"
}

notify_failure() {
  marker="$state_dir/last-failure-notification"
  if notification_is_due "$marker"; then
    notify_desktop \
      "AI tool update failed" \
      "The previous tools remain active. Inspect: journalctl -u nixos-ai-tools-update.service"
    record_notification "$marker"
  fi
}

cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$temporary_dir" ]; then
    rm -rf "$temporary_dir"
  fi
  if ((status != 0)) && [ "$operation" = update ]; then
    notify_failure
  fi
  pkill "-RTMIN+8" -x '\.waybar-wrapped|waybar' >/dev/null 2>&1 || true
  exit "$status"
}

record_success() {
  date +%s > "$state_dir/last-success.new"
  mv -f "$state_dir/last-success.new" "$state_dir/last-success"
  rm -f "$state_dir/last-failure-notification" "$state_dir/last-stale-notification"
}

check_stale() {
  now="$(date +%s)"
  successful="$(cat "$state_dir/last-success" 2>/dev/null || printf '0')"
  if [[ "$successful" =~ ^[0-9]+$ ]] && ((successful > 0 && now - successful < stale_seconds)); then
    return 0
  fi

  marker="$state_dir/last-stale-notification"
  if notification_is_due "$marker"; then
    notify_desktop \
      "AI tools have not updated recently" \
      "No successful check has completed within four hours. Inspect nixos-ai-tools-update.service."
    record_notification "$marker"
  fi
}

create_stage() {
  temporary_dir="$(mktemp -d)"
  staged_flake="$temporary_dir/flake"
  mkdir -p "$staged_flake"
  source_revision="$(git_at_flake rev-parse --verify HEAD)"
  git_at_flake archive --format=tar "$source_revision" | tar -xf - -C "$staged_flake"

  # Carry the independently advanced unstable lock forward only while every
  # other input still matches the live local-development baseline.
  if [ -f "$state_dir/flake.lock" ] \
    && non_fast_locks_match "$state_dir/flake.lock" "$flake_dir/flake.lock"; then
    cp "$state_dir/flake.lock" "$staged_flake/flake.lock"
  else
    cp "$flake_dir/flake.lock" "$staged_flake/flake.lock"
  fi
}

update_tools() {
  mkdir -p "$state_dir"
  exec 9>"$state_dir/update.lock"
  if ! flock -n 9; then
    printf 'Another AI-tools update is already running.\n'
    return 0
  fi

  create_stage
  candidate_lock="$temporary_dir/flake.lock"
  nix flake update "$fast_input" \
    --flake "path:$staged_flake" \
    --output-lock-file "$candidate_lock"
  cp "$candidate_lock" "$staged_flake/flake.lock"

  if [ -L "$state_dir/current" ] \
    && [ -e "$state_dir/current" ] \
    && [ -f "$state_dir/flake.lock" ] \
    && [ -f "$state_dir/source-revision" ] \
    && cmp -s "$candidate_lock" "$state_dir/flake.lock" \
    && [ "$source_revision" = "$(cat "$state_dir/source-revision")" ]; then
    record_success
    printf 'Claude, Codex, Pi, and T3 Code are already current.\n'
    return 0
  fi

  # Pi extensions are coupled to Pi's internal TypeScript API. Refuse to move
  # the shared profile if the newest package breaks those deployed extensions.
  nix build --no-link --print-build-logs \
    "path:$staged_flake#checks.x86_64-linux.pi-extensions"

  # Nix updates the out-link only after a successful build and registers that
  # exact stable pathname as an indirect GC root.
  nix build --print-build-logs \
    --out-link "$state_dir/current" \
    "path:$staged_flake#packages.x86_64-linux.aiTools"

  cp "$candidate_lock" "$state_dir/flake.lock.new"
  printf '%s\n' "$source_revision" > "$state_dir/source-revision.new"
  chmod 0644 "$state_dir/flake.lock.new" "$state_dir/source-revision.new"
  mv -f "$state_dir/flake.lock.new" "$state_dir/flake.lock"
  mv -f "$state_dir/source-revision.new" "$state_dir/source-revision"
  record_success
  printf 'Activated the newest checked AI-tool profile at %s.\n' "$(readlink -f "$state_dir/current")"
}

if [ "${AI_TOOLS_LIB_ONLY:-0}" != 1 ]; then
  require_runtime_commands
  if [ "$operation" = check-runtime ]; then
    printf 'AI-tools updater runtime is complete.\n'
    exit 0
  fi

  trap cleanup EXIT
  case "$operation" in
    update) update_tools ;;
    check-stale) check_stale ;;
    *)
      printf 'Usage: %s [update|check-stale|check-runtime]\n' "$0" >&2
      exit 2
      ;;
  esac
fi
