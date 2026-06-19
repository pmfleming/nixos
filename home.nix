{ config, inputs, lib, pkgs, unstablePkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;

  theme = import ./theme.nix;
  inherit (theme) palette fonts themeText;

  mkUserService = description: execStart: restartSec: {
    Unit = {
      Description = description;
      After = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = execStart;
      Restart = "always";
      RestartSec = restartSec;
    };

    Install.WantedBy = [ "default.target" ];
  };

  binShim = drv: name: lib.nameValuePair ".local/bin/${name}" {
    source = "${drv}/bin/${name}";
  };

  togglesplitPlugin = pkgs.stdenv.mkDerivation {
    pname = "hyprland-togglesplit";
    version = "local";
    src = ./packages/togglesplit;
    nativeBuildInputs = with pkgs; [ pkg-config ];
    buildInputs = with pkgs; [
      aquamarine
      hyprcursor
      hyprgraphics
      hyprland
      hyprlang
      hyprutils
      libdrm
      libglvnd
      libinput
      libxkbcommon
      mesa
      pango
      pixman
      systemd
      wayland
      xcbutilerrors
      xcbutilwm
    ];
    installPhase = ''
      runHook preInstall
      install -Dm755 togglesplit.so $out/lib/togglesplit.so
      runHook postInstall
    '';
  };

  hyprlandConfig = themeText (builtins.replaceStrings
    [ "@TOGGLESPLIT_PLUGIN@" "@HYPRPOLKITAGENT@" ]
    [ "${togglesplitPlugin}/lib/togglesplit.so" "${pkgs.hyprpolkitagent}" ]
    (builtins.readFile ./config/hypr/hyprland.conf));

  hyprMonitorAuto = pkgs.writeShellApplication {
    name = "hypr-monitor-auto";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
      procps
      socat
    ];
    text = ''
      last_state=""

      restart_waybar() {
        # Waybar can stay attached to the disabled output after a monitor swap.
        # Restart it through Hyprland so it binds to the currently visible output.
        sleep 0.5
        pkill -u "$(id -u)" -f '(^|/)waybar( |$)' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
          pgrep -u "$(id -u)" -f '(^|/)waybar( |$)' >/dev/null || break
          sleep 0.2
        done
        hyprctl dispatch exec "${pkgs.waybar}/bin/waybar >/dev/null 2>&1" >/dev/null || true
      }

      external_connected() {
        for status in /sys/class/drm/card*-DP-*/status /sys/class/drm/card*-HDMI-A-*/status; do
          [ -e "$status" ] || continue
          grep -q '^connected$' "$status" && return 0
        done
        return 1
      }

      custom_monitors_file="''${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.conf"

      custom_monitor_config_matches_state() {
        [ -f "$custom_monitors_file" ] || return 1
        grep -Eq '^[[:space:]]*monitor[[:space:]]*=' "$custom_monitors_file" || return 1

        if external_connected; then
          # Respect saved nwg-displays external layouts; ignore stale internal-only configs.
          # Match external connector names only at the start of the monitor field;
          # otherwise eDP-1 is accidentally treated as a DP-* external output.
          grep -Eq '^[[:space:]]*monitor[[:space:]]*=[[:space:]]*((DP-|HDMI-A-)|desc:)' "$custom_monitors_file"
        else
          grep -Eq '^[[:space:]]*monitor[[:space:]]*=[[:space:]]*eDP-' "$custom_monitors_file"
        fi
      }

      apply_state() {
        if custom_monitor_config_matches_state; then
          state="custom"
          if [ "$state" != "$last_state" ]; then
            restart_waybar
            last_state="$state"
          fi
          return 0
        fi

        if external_connected; then
          state="external"
          if [ "$state" != "$last_state" ]; then
            hyprctl keyword monitor ",preferred,auto,1.25" >/dev/null || true
            hyprctl keyword monitor "eDP-1,disable" >/dev/null || true
            restart_waybar
            last_state="$state"
          fi
        else
          state="internal"
          if [ "$state" != "$last_state" ]; then
            hyprctl keyword monitor "eDP-1,preferred,auto,1.25" >/dev/null || true
            restart_waybar
            last_state="$state"
          fi
        fi
      }

      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

      find_socket() {
        if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          socket="$runtime_dir/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
          [ -S "$socket" ] && printf '%s\n' "$socket" && return 0
        fi

        for socket in "$runtime_dir"/hypr/*/.socket2.sock; do
          [ -S "$socket" ] && printf '%s\n' "$socket" && return 0
        done

        return 1
      }

      export_instance_from_socket() {
        instance="''${1%/.socket2.sock}"
        export HYPRLAND_INSTANCE_SIGNATURE="''${instance##*/}"
      }

      while true; do
        while ! socket="$(find_socket)"; do
          sleep 1
        done

        export_instance_from_socket "$socket"
        apply_state

        socat -U - UNIX-CONNECT:"$socket" | while IFS= read -r event; do
          case "$event" in
            monitoradded*|monitorremoved*|configreloaded*) apply_state ;;
          esac
        done

        sleep 1
      done
    '';
  };

  togglesplitToggle = pkgs.writeShellApplication {
    name = "togglesplit-toggle";
    runtimeInputs = with pkgs; [
      hyprland
      jq
      libnotify
    ];
    text = ''
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
    '';
  };

  captivePortalBrowser = pkgs.writeShellApplication {
    name = "captive-portal-browser";
    runtimeInputs = with pkgs; [
      coreutils
      google-chrome
    ];
    text = ''
      set -euo pipefail

      profile_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/captive-portal-chrome"
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
    '';
  };

  rofiWifiMenu = pkgs.writeShellApplication {
    name = "rofi-wifi-menu";
    runtimeInputs = with pkgs; [
      captivePortalBrowser
      coreutils
      gawk
      gnused
      libnotify
      networkmanager
      rofi
    ];
    text = ''
      set -euo pipefail

      notify() {
        notify-send -a "Wi-Fi" "$@" >/dev/null 2>&1 || true
      }

      markup_escape() {
        printf '%s' "$1" \
          | sed \
              -e 's/&/\&amp;/g' \
              -e 's/</\&lt;/g' \
              -e 's/>/\&gt;/g'
      }

      current_ssid() {
        # `nmcli device wifi` can trigger a slow scan on first use. The explicit
        # cached list form stays fast and still gives the active SSID.
        nmcli -t -f IN-USE,SSID device wifi list --rescan no 2>/dev/null \
          | awk -F: '$1 == "*" { sub(/^[^:]*:/, ""); print; exit }' \
          | sed 's/\\:/:/g'
      }

      wifi_entries() {
        nmcli -m multiline -f IN-USE,SSID,SECURITY,SIGNAL,BARS device wifi list --rescan no 2>/dev/null \
          | awk '
              function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
              BEGIN { sep = sprintf("%c", 31) }
              function flush() {
                if (ssid == "") return
                sig = signal + 0
                if (!(ssid in best) || sig > bestSignal[ssid]) {
                  bestSignal[ssid] = sig
                  best[ssid] = active sep security sep signal sep bars
                }
              }
              /^IN-USE:/ { flush(); active = trim(substr($0, index($0, ":") + 1)); ssid = security = signal = bars = ""; next }
              /^SSID:/ { ssid = trim(substr($0, index($0, ":") + 1)); next }
              /^SECURITY:/ { security = trim(substr($0, index($0, ":") + 1)); next }
              /^SIGNAL:/ { signal = trim(substr($0, index($0, ":") + 1)); next }
              /^BARS:/ { bars = trim(substr($0, index($0, ":") + 1)); next }
              END {
                flush()
                for (s in best) print bestSignal[s] sep s sep best[s]
              }
            ' \
          | sort -t $'\037' -k1,1rn
      }

      network_count() {
        wifi_entries | wc -l | tr -d ' '
      }

      rescan_networks() {
        notify "Scanning Wi-Fi" "Refreshing nearby networks…"
        if nmcli device wifi rescan >/dev/null 2>&1; then
          # Give NetworkManager a moment to publish the refreshed AP list.
          sleep 2
          count="$(network_count)"
          notify "Wi-Fi scan complete" "$count networks found"
        else
          notify "Wi-Fi scan failed" "Could not refresh nearby networks"
        fi
      }

      open_captive_portal() {
        captive-portal-browser >/dev/null 2>&1 &
      }

      after_connect() {
        connected_ssid="$1"
        notify "Connected" "$connected_ssid"

        for _ in 1 2 3 4 5 6; do
          state="$(nmcli -t -f CONNECTIVITY general status 2>/dev/null || printf 'unknown')"
          case "$state" in
            full)
              return 0
              ;;
            portal|limited)
              notify "Captive portal detected" "Opening login page for $connected_ssid"
              open_captive_portal
              return 0
              ;;
          esac

          nmcli networking connectivity check >/dev/null 2>&1 || true
          sleep 2
        done
      }

      connect_saved_profile() {
        target_ssid="$1"
        while IFS=: read -r uuid type; do
          [ "$type" = "802-11-wireless" ] || continue
          profile_ssid="$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null | sed 's/\\:/:/g' || true)"
          if [ "$profile_ssid" = "$target_ssid" ]; then
            nmcli --wait 30 connection up uuid "$uuid" && return 0
          fi
        done < <(nmcli -t -f UUID,TYPE connection show)

        return 1
      }

      build_menu() {
        map_file="$1"
        rows_file="$(mktemp)"
        : > "$map_file"

        id=0
        while IFS=$'\037' read -r _sort_signal ssid active security signal _bars; do
          [ -n "$ssid" ] || continue
          id=$((id + 1))
          key="$(printf '%02d' "$id")"
          marker=" "
          [ "$active" = "*" ] && marker="●"
          security="''${security:---}"
          if [ "$security" = "--" ] || [ -z "$security" ]; then
            security_icon=""
          else
            security_icon=""
          fi

          signal_value="''${signal:-0}"
          if [ "$signal_value" -ge 85 ]; then
            signal_icon="󰤨"
          elif [ "$signal_value" -ge 65 ]; then
            signal_icon="󰤥"
          elif [ "$signal_value" -ge 45 ]; then
            signal_icon="󰤢"
          elif [ "$signal_value" -ge 25 ]; then
            signal_icon="󰤟"
          else
            signal_icon="󰤯"
          fi

          if [ "$signal_value" -ge 70 ]; then
            signal_color="${palette.success}"
          elif [ "$signal_value" -ge 45 ]; then
            signal_color="${palette.warning}"
          else
            signal_color="${palette.danger}"
          fi
          signal_percent="$(printf '%3s%%' "$signal_value")"
          signal_markup="$signal_icon <span foreground=\"$signal_color\">$signal_percent</span>"

          display_ssid="$ssid"
          # Some SSIDs genuinely start with '*'. Render that as a look-alike
          # glyph so it is not confused with the status/current column.
          case "$display_ssid" in
            \**) display_ssid="∗''${display_ssid:1}" ;;
          esac
          if [ "''${#display_ssid}" -gt 25 ]; then
            display_ssid="''${display_ssid:0:24}…"
          fi
          display_ssid="$(markup_escape "$display_ssid")"

          printf '%s\t%s\n' "$key" "$ssid" >> "$map_file"
          printf '%s  %s   %-25s %s %s\n' \
            "$key" "$marker" "$display_ssid" "$signal_markup" "$security_icon" >> "$rows_file"
        done < <(wifi_entries)

        printf '%s\n' \
          "r   󰑓  $id Networks (Rescan)" \
          "p   󰖟  Captive portal login"
        cat "$rows_file"
        rm -f "$rows_file"
      }

      # Keep the cache warming in the background without delaying the menu.
      nmcli device wifi rescan >/dev/null 2>&1 &

      while true; do
        current="$(current_ssid)"
        map_file="$(mktemp)"
        trap 'rm -f "$map_file"' EXIT
        menu="$(build_menu "$map_file")"
        choice="$(printf '%s\n' "$menu" | rofi -dmenu -i -markup-rows -p "Wi-Fi" || true)"
        [ -n "$choice" ] || exit 0

        key="$(printf '%s' "$choice" | awk '{print $1}')"
        case "$key" in
          r) rm -f "$map_file"; rescan_networks; continue ;;
          p) exec captive-portal-browser ;;
        esac

        ssid="$(awk -F '\t' -v key="$key" '$1 == key { print $2; exit }' "$map_file")"
        rm -f "$map_file"
        [ -n "$ssid" ] || exit 0

        if [ "$ssid" = "$current" ]; then
          notify "Already connected" "$ssid"
          after_connect "$ssid"
          exit 0
        fi

        if connect_saved_profile "$ssid"; then
          after_connect "$ssid"
          exit 0
        fi

        if nmcli --wait 30 device wifi connect "$ssid"; then
          after_connect "$ssid"
          exit 0
        fi

        password="$(rofi -dmenu -password -p "Password for $ssid" || true)"
        [ -n "$password" ] || exit 1

        if nmcli --wait 30 device wifi connect "$ssid" password "$password"; then
          after_connect "$ssid"
        else
          notify "Connection failed" "$ssid"
          exit 1
        fi
        exit 0
      done
    '';
  };

  rofiBluetoothMenu = pkgs.writeShellApplication {
    name = "rofi-bluetooth-menu";
    runtimeInputs = with pkgs; [
      bluez
      coreutils
      gawk
      gnused
      libnotify
      rofi
    ];
    text = ''
      set -euo pipefail

      notify() {
        notify-send -a "Bluetooth" "$@" >/dev/null 2>&1 || true
      }

      powered() {
        bluetoothctl show 2>/dev/null | awk -F': ' '/^[[:space:]]*Powered:/ { print $2; exit }'
      }

      device_field() {
        mac="$1"
        field="$2"
        bluetoothctl info "$mac" 2>/dev/null \
          | awk -F': ' -v field="$field" '$1 ~ "^[[:space:]]*" field "$" { print $2; exit }'
      }

      scan_devices() {
        bluetoothctl power on >/dev/null 2>&1 || true
        notify "Scanning" "Looking for nearby Bluetooth devices…"
        timeout 8s bluetoothctl scan on >/dev/null 2>&1 || true
        bluetoothctl scan off >/dev/null 2>&1 || true
      }

      build_menu() {
        map_file="$1"
        : > "$map_file"

        if ! bluetoothctl show >/dev/null 2>&1; then
          printf '%s\n' "x  󰂲  No Bluetooth controller found"
          return 0
        fi

        power="$(powered)"
        if [ "$power" = "yes" ]; then
          printf '%s\n' "t  󰂲  Turn Bluetooth off" "s  ⟳  Scan for devices"
        else
          printf '%s\n' "t  󰂯  Turn Bluetooth on"
        fi

        id=0
        while read -r _ mac name; do
          [ -n "''${mac:-}" ] || continue
          [ -n "''${name:-}" ] || name="$mac"
          id=$((id + 1))
          key="$(printf '%02d' "$id")"

          connected="$(device_field "$mac" Connected || true)"
          paired="$(device_field "$mac" Paired || true)"
          trusted="$(device_field "$mac" Trusted || true)"

          marker=" "
          status="new"
          if [ "$connected" = "yes" ]; then
            marker="●"
            status="connected"
          elif [ "$paired" = "yes" ]; then
            status="paired"
          fi
          [ "$trusted" = "yes" ] && status="$status trusted"

          printf '%s\t%s\t%s\n' "$key" "$mac" "$name" >> "$map_file"
          printf '%s  %s  %-34.34s  %s\n' "$key" "$marker" "$name" "$status"
        done < <(bluetoothctl devices 2>/dev/null | sort -k3)
      }

      connect_device() {
        mac="$1"
        name="$2"

        bluetoothctl power on >/dev/null 2>&1 || true
        bluetoothctl agent on >/dev/null 2>&1 || true
        bluetoothctl default-agent >/dev/null 2>&1 || true

        connected="$(device_field "$mac" Connected || true)"
        paired="$(device_field "$mac" Paired || true)"

        if [ "$connected" = "yes" ]; then
          if bluetoothctl disconnect "$mac" >/dev/null 2>&1; then
            notify "Disconnected" "$name"
            exit 0
          fi
          notify "Disconnect failed" "$name"
          exit 1
        fi

        if [ "$paired" != "yes" ]; then
          bluetoothctl pair "$mac" >/dev/null 2>&1 || true
        fi
        bluetoothctl trust "$mac" >/dev/null 2>&1 || true

        if bluetoothctl connect "$mac" >/dev/null 2>&1; then
          notify "Connected" "$name"
        else
          notify "Connection failed" "$name"
          exit 1
        fi
      }

      while true; do
        map_file="$(mktemp)"
        trap 'rm -f "$map_file"' EXIT
        power="$(powered || true)"
        menu="$(build_menu "$map_file")"
        message="Enter connects/disconnects • current: Bluetooth ''${power:-unknown}"
        choice="$(printf '%s\n' "$menu" | rofi -dmenu -i -p "Bluetooth" -mesg "$message" || true)"
        [ -n "$choice" ] || exit 0

        key="$(printf '%s' "$choice" | awk '{print $1}')"
        case "$key" in
          x) exit 0 ;;
          t)
            if [ "$(powered || true)" = "yes" ]; then
              bluetoothctl power off >/dev/null 2>&1 || true
              notify "Bluetooth off"
            else
              bluetoothctl power on >/dev/null 2>&1 || true
              notify "Bluetooth on"
            fi
            rm -f "$map_file"
            continue
            ;;
          s)
            rm -f "$map_file"
            scan_devices
            continue
            ;;
        esac

        mac="$(awk -F '\t' -v key="$key" '$1 == key { print $2; exit }' "$map_file")"
        name="$(awk -F '\t' -v key="$key" '$1 == key { print $3; exit }' "$map_file")"
        rm -f "$map_file"
        [ -n "$mac" ] || exit 0

        connect_device "$mac" "''${name:-$mac}"
        exit 0
      done
    '';
  };

  captivePortalMonitor = pkgs.writeShellApplication {
    name = "captive-portal-monitor";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
      libnotify
      networkmanager
    ];
    text = ''
      set -euo pipefail

      last_state=""
      last_opened=0
      cooldown=300

      notify() {
        notify-send -a "NetworkManager" "$@" >/dev/null 2>&1 || true
      }

      hypr_exec() {
        runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

        if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          hyprctl dispatch exec "$*" >/dev/null 2>&1 && return 0
        fi

        for socket in "$runtime_dir"/hypr/*/.socket.sock; do
          [ -S "$socket" ] || continue
          instance="''${socket%/.socket.sock}"
          export HYPRLAND_INSTANCE_SIGNATURE="''${instance##*/}"
          hyprctl dispatch exec "$*" >/dev/null 2>&1 && return 0
        done

        return 1
      }

      while true; do
        state="$(nmcli -t -f CONNECTIVITY general status 2>/dev/null || printf 'unknown')"
        now="$(date +%s)"

        case "$state" in
          portal|limited)
            if [ "$state" != "$last_state" ] || [ $((now - last_opened)) -ge "$cooldown" ]; then
              notify "Captive portal or limited network" "Connectivity is '$state'; opening plain-HTTP login pages."
              sleep 2
              if hypr_exec "${captivePortalBrowser}/bin/captive-portal-browser"; then
                last_opened="$now"
              fi
            fi
            ;;
          full)
            if [ "$last_state" = "portal" ] || [ "$last_state" = "limited" ]; then
              notify "Network online" "Connectivity check is full."
            fi
            ;;
        esac

        last_state="$state"
        sleep 10
      done
    '';
  };
in
{
  home.username = "laufan";
  home.homeDirectory = "/home/laufan";
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    hyprMonitorAuto
    togglesplitToggle
    captivePortalBrowser
    rofiWifiMenu
    rofiBluetoothMenu
    zenBrowser
    unstablePkgs.codex
    ghostty
    hyprlandGuiutils
    waybar
    hyprlock
    hyprpaper
    swayosd
    wlogout
    btop
    htop
  ];

  home.sessionVariables = {
    BROWSER = "zen";
    # Terminal editing defaults to nvim; Git is intentionally configured below
    # to use VS Code for commit messages and interactive operations.
    EDITOR = "nvim";
    VISUAL = "code --wait";
    GTK_THEME = "Adwaita:dark";
  };

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  gtk = {
    enable = true;
    theme.name = "Adwaita-dark";
    iconTheme.name = "Adwaita";
    cursorTheme = {
      name = "Bibata-Modern-Ice";
      package = pkgs.bibata-cursors;
      size = 24;
    };
    font = {
      name = fonts.mono;
      size = theme.ui.fontSizeInt;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk";
    style.name = "adwaita-dark";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Adwaita-dark";
    };
  };

  home.pointerCursor = {
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  xdg = {
    enable = true;
    mimeApps = {
      enable = true;
      defaultApplications = {
        "inode/directory" = "yazi.desktop";
        "text/html" = "zen.desktop";
        "x-scheme-handler/file" = "yazi.desktop";
        "x-scheme-handler/http" = "zen.desktop";
        "x-scheme-handler/https" = "zen.desktop";
      };
    };

    configFile = {
      "hypr/hyprland.conf".text = hyprlandConfig;
      "hypr/hyprlock.conf".text = themeText (builtins.replaceStrings
        [ "@WALLPAPER@" ]
        [ "${./assets/wallpaper.png}" ]
        (builtins.readFile ./config/hypr/hyprlock.conf));
      "hypr/hyprpaper.conf".text = builtins.replaceStrings
        [ "@WALLPAPER@" ]
        [ "${./assets/wallpaper.png}" ]
        (builtins.readFile ./config/hypr/hyprpaper.conf);
      "waybar/config".text = builtins.readFile ./config/waybar/config.jsonc;
      "waybar/style.css".text = themeText (builtins.readFile ./config/waybar/style.css);
      "waybar/zen-workspace.svg".source = ./config/waybar/zen-workspace.svg;
      "waybar/vscode-workspace.svg".source = ./config/waybar/vscode-workspace.svg;
      "waybar/spotify-workspace.svg".source = ./config/waybar/spotify-workspace.svg;
      "waybar/scratchpad-workspace.svg".source = ./config/waybar/scratchpad-workspace.svg;
      "rofi/config.rasi".text = themeText (builtins.readFile ./config/rofi/config.rasi);
      "ghostty/config".text = themeText (builtins.readFile ./config/ghostty/config);
      "xfce4/helpers.rc".text = ''
        TerminalEmulator=ghostty
      '';
      "xfce4/helpers/ghostty.desktop".text = ''
        [Desktop Entry]
        NoDisplay=true
        Version=1.0
        Type=X-XFCE-Helper
        X-XFCE-Category=TerminalEmulator
        Name=Ghostty
        X-XFCE-Commands=ghostty
        X-XFCE-CommandsWithParameter=ghostty --working-directory=%s
      '';
      "swaync/config.json".source = ./config/swaync/config.json;
      "swaync/style.css".text = themeText (builtins.readFile ./config/swaync/style.css);
    };

    desktopEntries.yazi = {
      name = "Yazi";
      genericName = "Terminal File Manager";
      comment = "Browse files in Yazi";
      exec = "ghostty -e yazi %f";
      terminal = false;
      mimeType = [
        "inode/directory"
      ];
      categories = [
        "System"
        "FileManager"
      ];
    };

    desktopEntries.pi = {
      name = "Pi";
      genericName = "AI Coding Assistant";
      comment = "Open Pi coding assistant";
      exec = "ghostty -e pi";
      terminal = false;
      categories = [
        "Development"
        "Utility"
      ];
    };

    desktopEntries.captive-portal-browser = {
      name = "Captive Portal Browser";
      genericName = "Captive Portal Browser";
      comment = "Open a clean Chrome profile on plain-HTTP captive portal check pages";
      exec = "captive-portal-browser";
      terminal = false;
      categories = [
        "Network"
        "WebBrowser"
      ];
    };
  };

  # User-level shims keep interactive launchers current even before the next
  # root-level NixOS profile switch updates /etc/profiles/per-user.
  home.file = lib.listToAttrs [
    (binShim rofiWifiMenu "rofi-wifi-menu")
    (binShim rofiBluetoothMenu "rofi-bluetooth-menu")
    (binShim captivePortalBrowser "captive-portal-browser")
  ] // {
    ".pi/agent/extensions/thinking-level-picker.ts".source = ./config/pi/thinking-level-picker.ts;
  };

  home.activation.retireLegacyHyprlandLua = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    legacy="$HOME/.config/hypr/hyprland.lua"
    backup="$legacy.hm-backup"

    if [ -e "$legacy" ] && [ ! -L "$legacy" ]; then
      if [ ! -e "$backup" ]; then
        mv "$legacy" "$backup"
      else
        rm "$legacy"
      fi
    fi
  '';

  home.activation.stopDuplicateNetworkTrayApplets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.procps}/bin/pkill -u "$USER" -x nm-applet >/dev/null 2>&1 || true
    ${pkgs.procps}/bin/pkill -u "$USER" -f '[b]lueman-applet' >/dev/null 2>&1 || true
  '';

  services.gnome-keyring.enable = true;
  services.poweralertd.enable = false;

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "hyprctl dispatch dpms on";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 420;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
        {
          timeout = 1800;
          on-timeout = "systemctl suspend";
        }
      ];
    };
  };

  systemd.user.services = {
    hypr-monitor-auto = mkUserService
      "Hyprland monitor auto-switcher"
      "${hyprMonitorAuto}/bin/hypr-monitor-auto"
      "2s";

    captive-portal-monitor = mkUserService
      "Notify and open a browser when NetworkManager detects a captive portal"
      "${captivePortalMonitor}/bin/captive-portal-monitor"
      "5s";
  };

  programs.bash.enable = true;

  programs.yazi = {
    enable = true;
    enableBashIntegration = true;

    settings = {
      mgr = {
        ratio = [ 1 3 4 ];
        show_hidden = true;
        sort_dir_first = true;
      };
      opener = {
        edit = [
          {
            run = ''${EDITOR:-nvim} "$@"'';
            block = true;
          }
        ];
        open = [
          {
            run = ''xdg-open "$1"'';
            orphan = true;
          }
        ];
      };
    };

    theme = {
      mgr = {
        cwd = { fg = palette.accent; };
        # Yazi is a terminal TUI, so it cannot draw real rounded outline boxes
        # around rows. Keep the selected row unfilled, white, and blue-underlined
        # to avoid the default pale-blue pill.
        hovered = {
          fg = palette.foreground;
          bg = "reset";
          bold = true;
          underline = true;
        };
        preview_hovered = {
          fg = palette.foreground;
          bg = "reset";
          bold = true;
          underline = true;
        };
        find_keyword = {
          fg = palette.accent;
          bold = true;
        };
        find_position = { fg = palette.subtext; };
        marker_copied = { fg = palette.success; };
        marker_cut = { fg = palette.danger; };
        marker_marked = { fg = palette.warning; };
        marker_selected = { fg = palette.accent; };
        tab_active = {
          fg = palette.black;
          bg = palette.accent;
        };
        tab_inactive = {
          fg = palette.subtext;
          bg = palette.bg;
        };
        border_symbol = "│";
        border_style = { fg = palette.borderDim; };
      };

      status = {
        separator_open = " ";
        separator_close = " ";
        separator_style = {
          fg = palette.bg;
          bg = palette.bg;
        };
        mode_normal = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        mode_select = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        mode_unset = {
          fg = palette.white;
          bg = palette.dangerDark;
          bold = true;
        };
        progress_label = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        progress_normal = {
          fg = palette.accentDark;
          bg = palette.bg;
        };
        progress_error = {
          fg = palette.dangerDark;
          bg = palette.bg;
        };
        permissions_t = { fg = palette.foreground; bold = true; };
        permissions_r = { fg = palette.foreground; bold = true; };
        permissions_w = { fg = palette.foreground; bold = true; };
        permissions_x = { fg = palette.foreground; bold = true; };
        permissions_s = { fg = palette.muted; };
      };

      input = {
        border = { fg = palette.accent; };
        title = { fg = palette.text; };
        value = { fg = palette.foreground; };
        selected = { bg = palette.selectedBg; };
      };

      select = {
        border = { fg = palette.accent; };
        active = { fg = palette.accent; };
        inactive = { fg = palette.subtext; };
      };

      tasks = {
        border = { fg = palette.accent; };
        title = { fg = palette.text; };
        hovered = { bg = palette.selectedBg; };
      };

      which = {
        cols = 3;
        mask = { bg = palette.bg; };
        cand = { fg = palette.accent; };
        desc = { fg = palette.subtext; };
        separator = "  ";
        separator_style = { fg = palette.muted; };
      };

      help = {
        on = { fg = palette.accent; };
        run = { fg = palette.subtext; };
        desc = { fg = palette.text; };
        hovered = { bg = palette.selectedBg; };
        footer = { fg = palette.bg; bg = palette.text; };
      };

      filetype = {
        rules = [
          { mime = "image/*"; fg = palette.foreground; }
          { mime = "video/*"; fg = palette.foreground; }
          { mime = "audio/*"; fg = palette.foreground; }
          { mime = "application/zip"; fg = palette.foreground; }
          { mime = "application/gzip"; fg = palette.foreground; }
          { mime = "application/x-tar"; fg = palette.foreground; }
          { url = "*/"; fg = palette.foreground; bold = true; }
          { url = "*"; fg = palette.foreground; }
        ];
      };
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Paul Fleming";
        email = "67100074+pmfleming@users.noreply.github.com";
      };
      core.editor = "code --wait";
    };
  };

  programs.home-manager.enable = true;
}
