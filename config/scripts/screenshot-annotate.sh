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

# Satty replaced Swappy because Swappy does not offer post-capture cropping.
# Smart resizing caps the editor at 80% of the active monitor while retaining
# the captured image's full output resolution.
satty \
  --filename "$raw" \
  --output-filename "$edited" \
  --resize smart \
  --early-exit \
  --actions-on-enter save-to-file \
  >/dev/null 2>&1 || exit 0
[ -s "$edited" ] || exit 0

wl-copy --type image/png < "$edited"
notify "Copied screenshot" "Available in clipboard history as an image item."
