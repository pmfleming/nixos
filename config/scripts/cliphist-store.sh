set -euo pipefail

# cliphist's built-in store deletes the latest history item when
# wl-paste reports CLIPBOARD_STATE=clear. With several MIME-specific
# watchers, one clear event could otherwise delete several history rows.
case "${CLIPBOARD_STATE:-}" in
  clear|sensitive) exit 0 ;;
esac

exec cliphist store "$@"
