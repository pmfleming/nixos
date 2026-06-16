{ config, inputs, lib, pkgs, unstablePkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;

  hyprMonitorAuto = pkgs.writeShellApplication {
    name = "hypr-monitor-auto";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
    ];
    text = ''
      last_state=""

      external_connected() {
        for status in /sys/class/drm/card*-DP-*/status /sys/class/drm/card*-HDMI-A-*/status; do
          [ -e "$status" ] || continue
          grep -q '^connected$' "$status" && return 0
        done
        return 1
      }

      while true; do
        if external_connected; then
          state="external"
          hyprctl keyword monitor ",preferred,auto,1.25" >/dev/null || true
          hyprctl keyword monitor "eDP-1,disable" >/dev/null || true
          last_state="$state"
        else
          state="internal"
          if [ "$state" != "$last_state" ]; then
            hyprctl keyword monitor "eDP-1,preferred,auto,1.25" >/dev/null || true
            last_state="$state"
          fi
        fi

        sleep 5
      done
    '';
  };

  nixosUpdateCheck = pkgs.writeShellApplication {
    name = "nixos-update-check";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      libnotify
      nix
    ];
    text = ''
      state_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      state_file="$state_dir/nixos-updates-available"
      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      rm -f "$state_file"

      if [ ! -f /etc/nixos/flake.lock ]; then
        exit 0
      fi

      if nix flake update --flake /etc/nixos --output-lock-file "$tmp_dir/flake.lock" >/dev/null 2>&1; then
        if ! cmp -s /etc/nixos/flake.lock "$tmp_dir/flake.lock"; then
          touch "$state_file"
          notify-send "NixOS updates available" "Flake inputs have newer versions. Apply them intentionally from /etc/nixos."
        fi
      fi
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
    nixosUpdateCheck
    togglesplitToggle
    zenBrowser
    unstablePkgs.codex
    ghostty
    hyprlandGuiutils
    waybar
    hyprlock
    hyprpaper
    btop
    htop
  ];

  home.sessionVariables = {
    BROWSER = "zen";
    EDITOR = "nvim";
    VISUAL = "code --wait";
    GIT_EDITOR = "code --wait";
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
      "hypr/hyprland.conf".source = ./config/hypr/hyprland.conf;
      "hypr/hyprlock.conf".source = ./config/hypr/hyprlock.conf;
      "hypr/hyprpaper.conf".source = ./config/hypr/hyprpaper.conf;
      "waybar/config".source = ./config/waybar/config.jsonc;
      "waybar/style.css".source = ./config/waybar/style.css;
      "waybar/zen-workspace.svg".source = ./config/waybar/zen-workspace.svg;
      "waybar/vscode-workspace.svg".source = ./config/waybar/vscode-workspace.svg;
      "waybar/spotify-workspace.svg".source = ./config/waybar/spotify-workspace.svg;
      "waybar/scratchpad-workspace.svg".source = ./config/waybar/scratchpad-workspace.svg;
      "rofi/config.rasi".source = ./config/rofi/config.rasi;
      "ghostty/config".source = ./config/ghostty/config;
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
      "swaync/style.css".source = ./config/swaync/style.css;
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
        cwd = { fg = "#2f8cff"; };
        # Yazi is a terminal TUI, so it cannot draw real rounded outline boxes
        # around rows. Keep the selected row unfilled, white, and blue-underlined
        # to avoid the default pale-blue pill.
        hovered = {
          fg = "#f5f5f5";
          bg = "reset";
          bold = true;
          underline = true;
        };
        preview_hovered = {
          fg = "#f5f5f5";
          bg = "reset";
          bold = true;
          underline = true;
        };
        find_keyword = {
          fg = "#2f8cff";
          bold = true;
        };
        find_position = { fg = "#aeb8c4"; };
        marker_copied = { fg = "#3fb950"; };
        marker_cut = { fg = "#f05a5a"; };
        marker_marked = { fg = "#f59e0b"; };
        marker_selected = { fg = "#2f8cff"; };
        tab_active = {
          fg = "#000000";
          bg = "#2f8cff";
        };
        tab_inactive = {
          fg = "#aeb8c4";
          bg = "#101418";
        };
        border_symbol = "│";
        border_style = { fg = "#141b22"; };
      };

      status = {
        separator_open = " ";
        separator_close = " ";
        separator_style = {
          fg = "#101418";
          bg = "#101418";
        };
        mode_normal = {
          fg = "#ffffff";
          bg = "#14508f";
          bold = true;
        };
        mode_select = {
          fg = "#ffffff";
          bg = "#14508f";
          bold = true;
        };
        mode_unset = {
          fg = "#ffffff";
          bg = "#8f2d2d";
          bold = true;
        };
        progress_label = {
          fg = "#ffffff";
          bg = "#14508f";
          bold = true;
        };
        progress_normal = {
          fg = "#14508f";
          bg = "#101418";
        };
        progress_error = {
          fg = "#8f2d2d";
          bg = "#101418";
        };
        permissions_t = { fg = "#f5f5f5"; bold = true; };
        permissions_r = { fg = "#f5f5f5"; bold = true; };
        permissions_w = { fg = "#f5f5f5"; bold = true; };
        permissions_x = { fg = "#f5f5f5"; bold = true; };
        permissions_s = { fg = "#69727d"; };
      };

      input = {
        border = { fg = "#2f8cff"; };
        title = { fg = "#d7dee8"; };
        value = { fg = "#f5f5f5"; };
        selected = { bg = "#26455f"; };
      };

      select = {
        border = { fg = "#2f8cff"; };
        active = { fg = "#2f8cff"; };
        inactive = { fg = "#aeb8c4"; };
      };

      tasks = {
        border = { fg = "#2f8cff"; };
        title = { fg = "#d7dee8"; };
        hovered = { bg = "#26455f"; };
      };

      which = {
        cols = 3;
        mask = { bg = "#101418"; };
        cand = { fg = "#2f8cff"; };
        desc = { fg = "#aeb8c4"; };
        separator = "  ";
        separator_style = { fg = "#69727d"; };
      };

      help = {
        on = { fg = "#2f8cff"; };
        run = { fg = "#aeb8c4"; };
        desc = { fg = "#d7dee8"; };
        hovered = { bg = "#26455f"; };
        footer = { fg = "#101418"; bg = "#d7dee8"; };
      };

      filetype = {
        rules = [
          { mime = "image/*"; fg = "#f5f5f5"; }
          { mime = "video/*"; fg = "#f5f5f5"; }
          { mime = "audio/*"; fg = "#f5f5f5"; }
          { mime = "application/zip"; fg = "#f5f5f5"; }
          { mime = "application/gzip"; fg = "#f5f5f5"; }
          { mime = "application/x-tar"; fg = "#f5f5f5"; }
          { url = "*/"; fg = "#f5f5f5"; bold = true; }
          { url = "*"; fg = "#f5f5f5"; }
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
    userName = "Paul Fleming";
    userEmail = "67100074+pmfleming@users.noreply.github.com";
    settings.core.editor = "code --wait";
  };

  programs.home-manager.enable = true;
}
