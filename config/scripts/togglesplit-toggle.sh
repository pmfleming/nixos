current="$(hyprctl getoption -j plugin:togglesplit:enabled | jq -r '.int')"

if [ "$current" = "1" ]; then
  next=false
  label=disabled
else
  next=true
  label=enabled
fi

hyprctl keyword plugin:togglesplit:enabled "$next" >/dev/null
notify-send "togglesplit $label"
