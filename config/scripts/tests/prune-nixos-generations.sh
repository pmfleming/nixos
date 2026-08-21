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
printf 'generation retention tests passed\n'
