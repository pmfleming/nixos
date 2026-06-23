{ config, inputs, lib, pkgs, unstablePkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  nmWifiRofi = inputs.nm-wifi-rofi.packages.${system}.default;
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

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
  mkScript = scriptLib.mkShellApplication pkgs;

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

  hyprMonitorAuto = mkScript {
    name = "hypr-monitor-auto";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
      procps
      socat
    ];
    replacements."@WAYBAR@" = "${pkgs.waybar}/bin/waybar";
    path = ./config/scripts/hypr-monitor-auto.sh;
  };

  togglesplitToggle = mkScript {
    name = "togglesplit-toggle";
    runtimeInputs = with pkgs; [
      hyprland
      jq
      libnotify
    ];
    path = ./config/scripts/togglesplit-toggle.sh;
  };

  captivePortalBrowser = mkScript {
    name = "captive-portal-browser";
    runtimeInputs = with pkgs; [
      coreutils
      google-chrome
    ];
    path = ./config/scripts/captive-portal-browser.sh;
  };

  rofiScriptHelpers = pkgs.writeText "rofi-helpers.sh" (scriptWith {} ./config/scripts/rofi-helpers.sh);
  rofiHelperReplacement = {
    "@ROFI_SCRIPT_HELPERS@" = "${rofiScriptHelpers}";
  };
  mkRofiScript = attrs: mkScript (attrs // {
    replacements = rofiHelperReplacement // (attrs.replacements or {});
  });

  rofiWifiMenu = mkRofiScript {
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
    replacements = {
      "@PALETTE_SUCCESS@" = palette.success;
      "@PALETTE_WARNING@" = palette.warning;
      "@PALETTE_DANGER@" = palette.danger;
      "@PALETTE_MUTED@" = palette.muted;
    };
    path = ./config/scripts/rofi-wifi-menu.sh;
  };

  cliphistStore = mkScript {
    name = "cliphist-store";
    runtimeInputs = with pkgs; [ cliphist ];
    path = ./config/scripts/cliphist-store.sh;
  };

  cliphistWatchers = {
    cliphist-text = {
      description = "Store text clipboard history with cliphist";
      mime = "text";
    };
    cliphist-image = {
      description = "Store image clipboard history with cliphist";
      mime = "image";
    };
    cliphist-uri-list = {
      description = "Store copied file URI clipboard history with cliphist";
      mime = "text/uri-list";
    };
    cliphist-gnome-copied-files = {
      description = "Store GNOME-style copied file clipboard history with cliphist";
      mime = "x-special/gnome-copied-files";
    };
  };

  mkCliphistWatcher = { description, mime }:
    mkUserService
      description
      "${pkgs.wl-clipboard}/bin/wl-paste --type ${mime} --watch ${cliphistStore}/bin/cliphist-store"
      "2s";

  rofiNmWifiMenu = mkRofiScript {
    name = "rofi-nm-wifi-menu";
    runtimeInputs = [
      nmWifiRofi
      pkgs.rofi
    ];
    path = ./config/scripts/rofi-nm-wifi-menu.sh;
  };

  rofiBluetoothMenu = mkRofiScript {
    name = "rofi-bluetooth-menu";
    runtimeInputs = with pkgs; [
      bluez
      coreutils
      gawk
      gnused
      libnotify
      rofi
    ];
    path = ./config/scripts/rofi-bluetooth-menu.sh;
  };

  rofiClipboardMenu = mkRofiScript {
    name = "rofi-clipboard-menu";
    runtimeInputs = with pkgs; [
      cliphist
      coreutils
      hyprland
      libnotify
      rofi
      swappy
      wl-clipboard
    ];
    path = ./config/scripts/rofi-clipboard-menu.sh;
  };

  screenshotAnnotate = mkScript {
    name = "screenshot-annotate";
    runtimeInputs = with pkgs; [
      coreutils
      grim
      libnotify
      slurp
      swappy
      wl-clipboard
    ];
    path = ./config/scripts/screenshot-annotate.sh;
  };

  rofiAppMenu = mkRofiScript {
    name = "rofi-app-menu";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.rofi
      rofiWifiMenu
      rofiBluetoothMenu
      rofiClipboardMenu
    ];
    path = ./config/scripts/rofi-app-menu.sh;
  };

  captivePortalMonitor = mkScript {
    name = "captive-portal-monitor";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
      libnotify
      networkmanager
    ];
    replacements."@CAPTIVE_PORTAL_BROWSER@" = "${captivePortalBrowser}/bin/captive-portal-browser";
    path = ./config/scripts/captive-portal-monitor.sh;
  };

  binShims = {
    rofi-app-menu = rofiAppMenu;
    rofi-wifi-menu = rofiWifiMenu;
    rofi-nm-wifi-menu = rofiNmWifiMenu;
    rofi-bluetooth-menu = rofiBluetoothMenu;
    rofi-clipboard-menu = rofiClipboardMenu;
    screenshot-annotate = screenshotAnnotate;
    captive-portal-browser = captivePortalBrowser;
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
    rofiNmWifiMenu
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
  home.file = lib.mapAttrs' (name: drv: binShim drv name) binShims // {
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

    wl-clip-persist = mkUserService
      "Keep the regular Wayland clipboard available after source apps exit"
      "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard regular"
      "2s";
  } // lib.mapAttrs (_: mkCliphistWatcher) cliphistWatchers;

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
