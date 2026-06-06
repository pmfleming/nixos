{ config, inputs, lib, pkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
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
          if [ "$state" != "$last_state" ]; then
            hyprctl keyword monitor ",preferred,auto,1" >/dev/null || true
            hyprctl keyword monitor "eDP-1,disable" >/dev/null || true
            last_state="$state"
          fi
        else
          state="internal"
          if [ "$state" != "$last_state" ]; then
            hyprctl keyword monitor "eDP-1,preferred,auto,1" >/dev/null || true
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
in
{
  home.username = "laufan";
  home.homeDirectory = "/home/laufan";
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    hyprMonitorAuto
    nixosUpdateCheck
    zenBrowser
    ghostty
    waybar
    hyprlock
    hyprpaper
    mako
    wofi
    btop
    htop
    kanshi
  ];

  home.sessionVariables = {
    BROWSER = "zen";
    EDITOR = "code --wait";
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
      size = 10;
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
        "text/html" = "zen.desktop";
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
      "rofi/config.rasi".source = ./config/rofi/config.rasi;
      "ghostty/config".source = ./config/ghostty/config;
      "swaync/config.json".source = ./config/swaync/config.json;
      "swaync/style.css".source = ./config/swaync/style.css;
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

  programs.git = {
    enable = true;
    settings.core.editor = "code --wait";
  };

  programs.home-manager.enable = true;
}
