{ config, inputs, lib, pkgs, unstablePkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;

  palette = {
    bg = "#101418";
    muted = "#69727d";
    text = "#d7dee8";
    subtext = "#aeb8c4";
    accent = "#2f8cff";
    accentBare = "2f8cff";

    # Extra terminal/TUI tones that are only consumed from Nix-native config.
    black = "#000000";
    white = "#ffffff";
    foreground = "#f5f5f5";
    borderDim = "#141b22";
    selectedBg = "#26455f";
    accentDark = "#14508f";
    dangerDark = "#8f2d2d";
    success = "#3fb950";
    danger = "#f05a5a";
    warning = "#f59e0b";
  };
  radius = "3px";

  themeText = text: builtins.replaceStrings
    [ "#101418" "#69727d" "#d7dee8" "#aeb8c4" "#2f8cff" "2f8cff" "@RADIUS@" ]
    [ palette.bg palette.muted palette.text palette.subtext palette.accent palette.accentBare radius ]
    text;

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
in
{
  home.username = "laufan";
  home.homeDirectory = "/home/laufan";
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    hyprMonitorAuto
    togglesplitToggle
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
      name = "JetBrainsMono Nerd Font";
      size = 12;
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
  };

  home.file.".pi/agent/extensions/thinking-level-picker.ts".source = ./config/pi/thinking-level-picker.ts;

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

  systemd.user.services.hypr-monitor-auto = {
    Unit = {
      Description = "Hyprland monitor auto-switcher";
      After = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = "${hyprMonitorAuto}/bin/hypr-monitor-auto";
      Restart = "always";
      RestartSec = "2s";
    };

    Install.WantedBy = [ "default.target" ];
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
