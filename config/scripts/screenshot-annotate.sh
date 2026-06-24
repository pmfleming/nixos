set -euo pipefail

notify() {
  notify-send -a "Screenshot" "$@" >/dev/null 2>&1 || true
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
raw="$tmp_dir/capture.png"
edited="$tmp_dir/edited.png"

geometry="$(slurp || true)"
[ -n "$geometry" ] || exit 0

grim -g "$geometry" "$raw"

# Swappy's own clipboard button can race/confuse history. Instead, write
# the final annotated image to a file, copy it once with an explicit MIME
# type, and let the wl-paste/cliphist image watcher store exactly that.
swappy -f "$raw" -o "$edited" >/dev/null 2>&1 || exit 0
[ -s "$edited" ] || exit 0

wl-copy --type image/png < "$edited"
notify "Copied screenshot" "Available in clipboard history as an image item."
