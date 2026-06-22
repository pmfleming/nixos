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

  rofiScriptHelpers = pkgs.writeText "rofi-script-helpers.sh" ''
    markup_escape() {
      printf '%s' "$1" \
        | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g'
    }

    rofi_header() {
      printf '\0%s\x1f%s\n' "$1" "$2"
    }

    rofi_common_headers() {
      prompt="$1"
      message="''${2:-}"
      rofi_header prompt "$prompt"
      rofi_header markup-rows true
      rofi_header no-custom true
      [ -z "$message" ] || rofi_header message "$message"
    }

    rofi_row() {
      search="$1"
      info="$2"
      display="$3"

      printf '%s\0display\x1f%s' "$search" "$display"
      [ -z "$info" ] || printf '\x1finfo\x1f%s' "$info"
      printf '\n'
    }

    rofi_static_row() {
      search="$1"
      display="$2"

      printf '%s\0display\x1f%s\x1fnonselectable\x1ftrue\n' "$search" "$display"
    }

    rofi_script_launch() {
      mode="$1"
      prompt="$2"
      shift 2

      exec rofi -show "$mode" -modes "$mode:$0" -i -p "$prompt" "$@"
    }

    hypr_active_window_paste_context() {
      target="activewindow"
      class=""

      if ! command -v hyprctl >/dev/null 2>&1; then
        printf 'none|%s|%s\n' "$target" "$class"
        return 0
      fi

      while IFS= read -r line; do
        case "$line" in
          Window\ *\ -\>*)
            address="''${line#Window }"
            address="''${address%% ->*}"
            address="''${address#0x}"
            [ -z "$address" ] || target="address:0x$address"
            ;;
          *class:\ *)
            class="''${line#*: }"
            ;;
        esac
      done < <(hyprctl activewindow 2>/dev/null || true)

      printf 'hyprland|%s|%s\n' "$target" "$class"
    }
  '';

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
      # shellcheck source=/dev/null
      source ${rofiScriptHelpers}

      notify() {
        notify-send -a "Wi-Fi" "$@" >/dev/null 2>&1 || true
      }

      current_ssid() {
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

      refresh_wifi_cache() {
        scan_rc=0
        nmcli --wait 8 device wifi rescan >/dev/null 2>&1 || scan_rc=$?
        sleep 2
        return "$scan_rc"
      }

      refresh_wifi_cache_with_progress() {
        nmcli --wait 8 device wifi rescan >/dev/null 2>&1 &
        scan_pid="$!"
        elapsed=0

        while kill -0 "$scan_pid" 2>/dev/null; do
          rofi_header message "Scanning Wi-Fi… ''${elapsed}s elapsed. Waiting for NetworkManager."
          elapsed=$((elapsed + 1))
          sleep 1
        done

        scan_rc=0
        wait "$scan_pid" || scan_rc=$?
        rofi_header message "Publishing refreshed Wi-Fi list…"
        sleep 2
        return "$scan_rc"
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

      saved_wifi_profiles() {
        while IFS=: read -r uuid type; do
          [ "$type" = "802-11-wireless" ] || continue
          profile_ssid="$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null | sed 's/\\:/:/g' || true)"
          [ -n "$profile_ssid" ] || continue
          printf '%s\n' "$profile_ssid"
        done < <(nmcli -t -f UUID,TYPE connection show)
      }

      display_ssid() {
        label="$1"
        case "$label" in
          \**) label="∗''${label:1}" ;;
        esac
        if [ "''${#label}" -gt 25 ]; then
          label="''${label:0:24}…"
        fi
        markup_escape "$label"
      }

      visible_wifi_row() {
        id="$1"
        ssid="$2"
        active="$3"
        security="$4"
        signal="$5"

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
        display="$(printf '%s  %s   %-25s %s %s' "$key" "$marker" "$(display_ssid "$ssid")" "$signal_markup" "$security_icon")"
        printf -v info 'connect\t%s' "$ssid"
        rofi_row "$ssid" "$info" "$display"
      }

      saved_wifi_row() {
        id="$1"
        ssid="$2"
        key="$(printf '%02d' "$id")"
        display="$(printf '%s  %s   %-25s %s %s' "$key" "◇" "$(display_ssid "$ssid")" "<span foreground=\"${palette.muted}\">saved</span>" "")"
        printf -v info 'connect\t%s' "$ssid"
        rofi_row "$ssid" "$info" "$display"
      }

      emit_wifi_menu() {
        message="''${1:-Enter connects • saved profiles are shown when not currently visible}"
        rows_file="$(mktemp)"
        : > "$rows_file"

        id=0
        visible_count=0
        declare -A seen_ssids=()

        while IFS=$'\037' read -r _sort_signal ssid active security signal _bars; do
          [ -n "$ssid" ] || continue
          seen_ssids["$ssid"]=1
          id=$((id + 1))
          visible_wifi_row "$id" "$ssid" "$active" "$security" "$signal" >> "$rows_file"
        done < <(wifi_entries)
        visible_count="$id"

        while IFS= read -r ssid; do
          [ -n "$ssid" ] || continue
          [ -z "''${seen_ssids[$ssid]+x}" ] || continue
          seen_ssids["$ssid"]=1
          id=$((id + 1))
          saved_wifi_row "$id" "$ssid" >> "$rows_file"
        done < <(saved_wifi_profiles)

        rofi_common_headers "Wi-Fi" "$message"
        rofi_row "rescan" "rescan" "r   󰑓  $visible_count Visible (Rescan)"
        rofi_row "captive portal" "portal" "p   󰖟  Captive portal login"
        cat "$rows_file"
        rm -f "$rows_file"
      }

      connect_wifi() {
        ssid="$1"
        current="$(current_ssid)"

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
      }

      if [ -z "''${ROFI_RETV:-}" ]; then
        rofi_script_launch wifi "Wi-Fi" -markup-rows
      fi

      tab=$'\t'
      info="''${ROFI_INFO:-}"
      case "$info" in
        rescan)
          rofi_common_headers "Wi-Fi" "Scanning Wi-Fi…"
          rofi_static_row "scanning" "󰑓  Scanning Wi-Fi…"
          if refresh_wifi_cache_with_progress; then
            count="$(network_count)"
            emit_wifi_menu "Scan complete: $count visible networks."
          else
            emit_wifi_menu "Scan failed; showing cached and saved networks."
          fi
          ;;
        portal)
          open_captive_portal
          ;;
        connect"$tab"*)
          connect_wifi "''${info#connect"$tab"}"
          ;;
        *)
          emit_wifi_menu
          ;;
      esac
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
      # shellcheck source=/dev/null
      source ${rofiScriptHelpers}

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

      scan_devices_with_progress() {
        bluetoothctl power on >/dev/null 2>&1 || true
        timeout 8s bluetoothctl scan on >/dev/null 2>&1 &
        scan_pid="$!"
        elapsed=0

        while kill -0 "$scan_pid" 2>/dev/null; do
          rofi_header message "Scanning Bluetooth… ''${elapsed}s elapsed."
          elapsed=$((elapsed + 1))
          sleep 1
        done

        wait "$scan_pid" >/dev/null 2>&1 || true
        bluetoothctl scan off >/dev/null 2>&1 || true
      }

      bluetooth_device_row() {
        id="$1"
        mac="$2"
        name="$3"
        [ -n "$name" ] || name="$mac"

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

        key="$(printf '%02d' "$id")"
        safe_name="$(markup_escape "$name")"
        display="$(printf '%s  %s  %-34.34s  %s' "$key" "$marker" "$safe_name" "$status")"
        printf -v info 'device\t%s\t%s' "$mac" "$name"
        rofi_row "$name $mac" "$info" "$display"
      }

      emit_bluetooth_menu() {
        message="''${1:-Enter connects/disconnects}"
        rows_file="$(mktemp)"
        : > "$rows_file"

        rofi_common_headers "Bluetooth" "$message"

        if ! bluetoothctl show >/dev/null 2>&1; then
          rofi_static_row "no controller" "󰂲  No Bluetooth controller found"
          rm -f "$rows_file"
          return 0
        fi

        power="$(powered || true)"
        if [ "$power" = "yes" ]; then
          rofi_row "toggle bluetooth" "toggle" "t  󰂲  Turn Bluetooth off"
          rofi_row "scan bluetooth" "scan" "s  ⟳  Scan for devices"
        else
          rofi_row "toggle bluetooth" "toggle" "t  󰂯  Turn Bluetooth on"
        fi

        id=0
        while read -r _ mac name; do
          [ -n "''${mac:-}" ] || continue
          id=$((id + 1))
          bluetooth_device_row "$id" "$mac" "''${name:-$mac}" >> "$rows_file"
        done < <(bluetoothctl devices 2>/dev/null | sort -k3)

        cat "$rows_file"
        rm -f "$rows_file"
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

      if [ -z "''${ROFI_RETV:-}" ]; then
        rofi_script_launch bluetooth "Bluetooth" -markup-rows
      fi

      tab=$'\t'
      info="''${ROFI_INFO:-}"
      case "$info" in
        toggle)
          if [ "$(powered || true)" = "yes" ]; then
            bluetoothctl power off >/dev/null 2>&1 || true
            notify "Bluetooth off"
            emit_bluetooth_menu "Bluetooth is off."
          else
            bluetoothctl power on >/dev/null 2>&1 || true
            notify "Bluetooth on"
            emit_bluetooth_menu "Bluetooth is on."
          fi
          ;;
        scan)
          rofi_common_headers "Bluetooth" "Scanning Bluetooth…"
          rofi_static_row "scanning" "⟳  Scanning for Bluetooth devices…"
          scan_devices_with_progress
          emit_bluetooth_menu "Bluetooth scan complete."
          ;;
        device"$tab"*)
          rest="''${info#device"$tab"}"
          mac="''${rest%%"$tab"*}"
          name="''${rest#*"$tab"}"
          connect_device "$mac" "''${name:-$mac}"
          ;;
        *)
          power="$(powered || true)"
          emit_bluetooth_menu "Enter connects/disconnects • current: Bluetooth ''${power:-unknown}"
          ;;
      esac
    '';
  };

  rofiClipboardMenu = pkgs.writeShellApplication {
    name = "rofi-clipboard-menu";
    runtimeInputs = with pkgs; [
      cliphist
      hyprland
      libnotify
      rofi
      wl-clipboard
    ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source ${rofiScriptHelpers}

      notify() {
        notify-send -a "Clipboard" "$@" >/dev/null 2>&1 || true
      }

      # Single arbiter of "is this entry a stored image?". cliphist renders
      # binary as a "[[ binary data <size> <type> <dims> ]]" placeholder; in this
      # config the only binary entries are png screenshots (the wl-paste image
      # watcher and the screenshot pipeline both store image/png). A predicate
      # (return code, not echo) keeps the per-row menu loop fork-free.
      clip_is_image() {
        case "$1" in
          "[[ binary data "*) return 0 ;;
          *) return 1 ;;
        esac
      }

      clipboard_row() {
        entry="$1"
        id="''${entry%%"$tab"*}"
        preview="''${entry#*"$tab"}"

        if clip_is_image "$preview"; then
          text="''${preview#\[\[ binary data }"
          text="''${text% \]\]}"
          text="''${text//x/×}"
          icon=$'\uf03e'
          search="$id image screenshot $text"
        else
          text="$preview"
          icon=$'\uf0ea'
          search="$preview"
        fi

        display="$(printf '%-4s  %s  %s' "$id" "$icon" "$(markup_escape "$text")")"

        printf -v info 'paste\t%s' "$entry"
        rofi_row "$search" "$info" "$display"
      }

      # Resolve "backend|target|class" for the window focused before rofi
      # opened. ROFI_DATA carries it across script reentry; ROFI_CLIPBOARD_TARGET
      # is the launch-time export; the live query is the last-resort fallback.
      clipboard_context() {
        printf '%s' "''${ROFI_DATA:-''${ROFI_CLIPBOARD_TARGET:-$(hypr_active_window_paste_context)}}"
      }

      split_paste_context() {
        context="$1"
        paste_backend="''${context%%|*}"
        rest="''${context#*|}"
        paste_target="''${rest%%|*}"
        paste_class="''${rest#*|}"
        [ "$paste_class" != "$rest" ] || paste_class=""
      }

      paste_shortcut_for_class() {
        case "$1" in
          com.mitchellh.ghostty|ghostty|Ghostty|Alacritty|alacritty|kitty|foot|footclient|org.wezfurlong.wezterm|org.gnome.Terminal|org.gnome.Console|org.kde.konsole|konsole|Ptyxis|dev.warp.Warp|com.raggesilver.BlackBox)
            printf 'CTRL_SHIFT,V'
            ;;
          *)
            printf 'CTRL,V'
            ;;
        esac
      }

      send_paste_shortcut() {
        context="$1"
        shortcut="$2"
        split_paste_context "$context"

        case "$paste_backend" in
          hyprland)
            hyprctl dispatch sendshortcut "$shortcut,$paste_target" >/dev/null 2>&1
            ;;
          *)
            return 1
            ;;
        esac
      }

      emit_clipboard_menu() {
        context="$(clipboard_context)"
        rofi_common_headers "Paste" "Enter pastes selected item • screenshot images are marked "
        rofi_header data "$context"
        rofi_row "clear clipboard history" "clear" "󰆴  Clear clipboard history"

        count=0
        while IFS= read -r entry; do
          [ -n "$entry" ] || continue
          count=$((count + 1))
          clipboard_row "$entry"
        done < <(cliphist list 2>/dev/null || true)

        if [ "$count" -eq 0 ]; then
          rofi_static_row "no clipboard history" "No clipboard history"
        fi
      }

      paste_entry() {
        entry="$1"
        preview="''${entry#*"$tab"}"

        if clip_is_image "$preview"; then
          printf '%s\n' "$entry" | cliphist decode | wl-copy --sensitive --type image/png
        else
          printf '%s\n' "$entry" | cliphist decode | wl-copy --sensitive
        fi

        context="$(clipboard_context)"
        split_paste_context "$context"
        shortcut="$(paste_shortcut_for_class "$paste_class")"

        # Compositor-native paste backend: Hyprland sends the chosen shortcut
        # directly to the window that was focused before rofi opened. The
        # per-app shortcut map above handles terminals that paste with
        # Ctrl+Shift+V instead of Ctrl+V. wl-copy --sensitive tells the cliphist
        # watcher not to re-store/dedupe this paste, so selecting an item does
        # not move or remove it from history.
        if send_paste_shortcut "$context" "$shortcut"; then
          notify "Pasted from history" "$preview"
        else
          notify "Paste shortcut failed" "Item is on the clipboard; press paste manually."
        fi
      }

      if [ -z "''${ROFI_RETV:-}" ]; then
        ROFI_CLIPBOARD_TARGET="$(hypr_active_window_paste_context)"
        export ROFI_CLIPBOARD_TARGET
        rofi_script_launch clipboard "Paste" -markup-rows
      fi

      tab=$'\t'
      info="''${ROFI_INFO:-}"
      case "$info" in
        clear)
          cliphist wipe
          notify "Clipboard history cleared"
          emit_clipboard_menu
          ;;
        paste"$tab"*)
          paste_entry "''${info#paste"$tab"}"
          ;;
        *)
          emit_clipboard_menu
          ;;
      esac
    '';
  };

  screenshotAnnotate = pkgs.writeShellApplication {
    name = "screenshot-annotate";
    runtimeInputs = with pkgs; [
      coreutils
      grim
      libnotify
      slurp
      swappy
      wl-clipboard
    ];
    text = ''
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
    '';
  };

  rofiAppMenu = pkgs.writeShellApplication {
    name = "rofi-app-menu";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.rofi
      rofiWifiMenu
      rofiBluetoothMenu
      rofiClipboardMenu
    ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source ${rofiScriptHelpers}

      ROFI_CLIPBOARD_TARGET="$(hypr_active_window_paste_context)"
      export ROFI_CLIPBOARD_TARGET

      # Keep apps on rofi's native drun mode rather than cloning desktop-entry
      # parsing. Wi-Fi/Bluetooth/Paste are script modes in the same menu.
      exec rofi -show drun -modes "drun,run,window,wifi:rofi-wifi-menu,bluetooth:rofi-bluetooth-menu,clipboard:rofi-clipboard-menu" -i
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
    rofiAppMenu
    rofiWifiMenu
    rofiBluetoothMenu
    rofiClipboardMenu
    screenshotAnnotate
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
  ];

  home.sessionVariables = {
    BROWSER = "zen";
    # Terminal editing defaults to nvim; Git is intentionally configured below
    # to use VS Code for commit messages and interactive operations.
    EDITOR = "nvim";
    VISUAL = "code --wait";
    GTK_THEME = theme.appearance.gtkThemeEnv;
  };

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  gtk = {
    enable = true;
    theme.name = theme.appearance.gtkTheme;
    iconTheme.name = theme.appearance.iconTheme;
    cursorTheme = {
      name = theme.appearance.cursorTheme;
      package = pkgs.bibata-cursors;
      size = theme.appearance.cursorSize;
    };
    font = {
      name = fonts.mono;
      size = theme.ui.fontSizeInt;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = theme.appearance.qtPlatformThemeName;
    style.name = theme.appearance.qtStyle;
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = theme.appearance.gtkColorScheme;
      gtk-theme = theme.appearance.gtkTheme;
    };
  };

  home.pointerCursor = {
    name = theme.appearance.cursorTheme;
    package = pkgs.bibata-cursors;
    size = theme.appearance.cursorSize;
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
      icon = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/legacy/system-file-manager-symbolic.svg";
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
      icon = "${./assets/pi-logo-on-dark.svg}";
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
    (binShim rofiAppMenu "rofi-app-menu")
    (binShim rofiWifiMenu "rofi-wifi-menu")
    (binShim rofiBluetoothMenu "rofi-bluetooth-menu")
    (binShim rofiClipboardMenu "rofi-clipboard-menu")
    (binShim screenshotAnnotate "screenshot-annotate")
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
