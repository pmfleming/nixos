set -euo pipefail

script_path=$1
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
export PRUNE_TEST_LOG="$test_root/deleted"

printf '#!%s\n' "$(command -v bash)" > "$test_root/bin/nix-env"
cat >> "$test_root/bin/nix-env" <<'EOF'
set -euo pipefail

case " $* " in
  *" --list-generations "*)
    if [ "${PRUNE_TEST_SMALL_PROFILE:-0}" = 1 ]; then
      printf '1 2020-01-01 00:00:00\n'
      exit 0
    fi
    cat <<'GENERATIONS'
1 invalid-date 00:00:00
2 2020-01-01 00:00:00
3 2020-02-01 00:00:00
4 2020-03-01 00:00:00
5 2020-04-01 00:00:00
6 2020-05-01 00:00:00
7 2020-06-01 00:00:00
8 2020-07-01 00:00:00
GENERATIONS
    ;;
  *" --delete-generations "*)
    while (( $# )); do
      if [ "$1" = --delete-generations ]; then
        shift
        printf '%s\n' "$*" > "$PRUNE_TEST_LOG"
        exit 0
      fi
      shift
    done
    ;;
  *)
    printf 'Unexpected nix-env arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$test_root/bin/nix-env"

PATH="$test_root/bin:$PATH" bash "$script_path" \
  --profile "$test_root/profile" \
  --no-refresh-boot

# The five newest generations are retained. The malformed oldest generation is
# also retained fail-safe, leaving only generations 2 and 3 eligible for deletion.
[ "$(cat "$PRUNE_TEST_LOG")" = "2 3" ]
# A staged generation can differ from /run/current-system. Boot refresh must
# use the profile's target in both the pruning and small-profile code paths.
mkdir -p "$test_root/staged-system/bin"
export PRUNE_TEST_BOOT_LOG="$test_root/boot-log"
printf '#!%s\n' "$(command -v bash)" > "$test_root/staged-system/bin/switch-to-configuration"
cat >> "$test_root/staged-system/bin/switch-to-configuration" <<'EOF'
set -euo pipefail
printf '%s %s\n' "$0" "$*" >> "$PRUNE_TEST_BOOT_LOG"
exit "${PRUNE_TEST_BOOT_STATUS:-0}"
EOF
chmod +x "$test_root/staged-system/bin/switch-to-configuration"
ln -s "$test_root/staged-system" "$test_root/profile"

for small in 0 1; do
  PATH="$test_root/bin:$PATH" PRUNE_TEST_SMALL_PROFILE=$small \
    bash "$script_path" --profile "$test_root/profile"
done
[ "$(wc -l < "$PRUNE_TEST_BOOT_LOG")" -eq 2 ]
[ "$(sort -u "$PRUNE_TEST_BOOT_LOG")" = "$test_root/staged-system/bin/switch-to-configuration boot" ]

PATH="$test_root/bin:$PATH" PRUNE_TEST_BOOT_STATUS=11 \
  bash "$script_path" --profile "$test_root/profile"
if PATH="$test_root/bin:$PATH" PRUNE_TEST_BOOT_STATUS=1 \
  bash "$script_path" --profile "$test_root/profile"; then
  printf 'A boot refresh failure was ignored.\n' >&2
  exit 1
fi

# Fail before deleting anything when the intended boot target is unavailable.
rm "$test_root/profile" "$PRUNE_TEST_LOG"
if PATH="$test_root/bin:$PATH" bash "$script_path" --profile "$test_root/profile"; then
  printf 'A missing boot target was accepted.\n' >&2
  exit 1
fi
[ ! -e "$PRUNE_TEST_LOG" ]
printf 'generation retention tests passed\n'
