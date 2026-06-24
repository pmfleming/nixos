set -euo pipefail

profile_dir="${XDG_DATA_HOME:-$HOME/.local/share}/captive-portal-chrome"
mkdir -p "$profile_dir"

if [ "$#" -eq 0 ]; then
  set -- \
    "http://example.com" \
    "http://captive.apple.com/hotspot-detect.html" \
    "http://www.msftconnecttest.com/connecttest.txt" \
    "http://nmcheck.gnome.org/check_network_status.txt"
fi

exec google-chrome-stable \
  --user-data-dir="$profile_dir" \
  --no-first-run \
  --no-default-browser-check \
  --disable-search-engine-choice-screen \
  --new-window \
  --disable-extensions \
  --disable-quic \
  --disable-features=HttpsUpgrades,HttpsFirstBalancedModeAutoEnable,HttpsFirstModeV2,DnsOverHttpsUpgrade \
  --no-proxy-server \
  "$@"
