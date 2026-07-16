{ config, inputs, lib, pkgs, unstablePkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  nmDaemon = inputs.nm-daemon.packages.${system}.default;
  shelllistWifi = inputs.shelllist.packages.${system}.default;
  shelllistPortalBrowser = inputs.shelllist.packages.${system}.captivePortalBrowser;
  scratchpad = inputs.scratchpad.packages.${system}.scratchpad-hyprland;
  tsReactQualityLens = inputs.ts-react-quality-lens.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;

  theme = import ./theme.nix;
  inherit (theme) palette fonts themeText wallpaper;

  sharedSessionVariables = {
    GTK_THEME = theme.appearance.gtkThemeEnv;
    QT_QPA_PLATFORM = "wayland;xcb";
    QT_QPA_PLATFORMTHEME = theme.appearance.qtPlatformThemeEnv;
    SHELLLIST_WIFI_MODE = "popover";
    SHELLLIST_BG = palette.bg;
    SHELLLIST_SURFACE = palette.borderDim;
    SHELLLIST_TEXT = palette.text;
    SHELLLIST_SUBTEXT = palette.subtext;
    SHELLLIST_ACCENT = palette.accent;
    SHELLLIST_SELECTED = palette.selectedBg;
    SHELLLIST_BORDER = palette.borderDim;
    SHELLLIST_SUCCESS = palette.success;
    SHELLLIST_WARNING = palette.warning;
    SHELLLIST_RADIUS = builtins.toString theme.ui.radiusInt;
  };

  hyprlandEnvVariables = sharedSessionVariables // {
    XCURSOR_SIZE = builtins.toString theme.appearance.cursorSize;
    HYPRCURSOR_SIZE = builtins.toString theme.appearance.cursorSize;
    NIXOS_OZONE_WL = "1";
  };

  hyprlandEnvConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: "env = ${name},${builtins.toString value}") hyprlandEnvVariables
  );

  mkUserService = description: execStart: restartSec: {
    Unit = {
      Description = description;
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = execStart;
      Restart = "always";
      RestartSec = restartSec;
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };

  binShim = drv: name: lib.nameValuePair ".local/bin/${name}" {
    source = "${drv}/bin/${name}";
  };

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
  mkScript = scriptLib.mkShellApplication pkgs;

  hyprlandConfig = themeText (scriptWith {
    "@HYPRLAND_ENV@" = hyprlandEnvConfig;
    "@HYPRPOLKITAGENT@" = "${pkgs.hyprpolkitagent}";
    "@SCRATCHPAD@" = "${scratchpad}/bin/scratchpad";
    "@DBUS_UPDATE_ACTIVATION_ENVIRONMENT@" = "${pkgs.dbus}/bin/dbus-update-activation-environment";
    "@SYSTEMCTL@" = "${pkgs.systemd}/bin/systemctl";
  } ./config/hypr/hyprland.conf);

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

  rofiScriptHelpers = pkgs.writeText "rofi-helpers.sh" (scriptWith {} ./config/scripts/rofi-helpers.sh);
  rofiHelperReplacement = {
    "@ROFI_SCRIPT_HELPERS@" = "${rofiScriptHelpers}";
  };
  mkRofiScript = attrs: mkScript (attrs // {
    replacements = rofiHelperReplacement // (attrs.replacements or {});
  });

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
      satty
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
      satty
      wl-clipboard
    ];
    path = ./config/scripts/screenshot-annotate.sh;
  };

  rofiAppMenu = mkRofiScript {
    name = "rofi-app-menu";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnused
      gtk3
      hyprland
      jq
      rofi
      util-linux
      rofiBluetoothMenu
      rofiClipboardMenu
    ];
    replacements = {
      "@PALETTE_SUCCESS@" = palette.success;
      "@PALETTE_MUTED@" = palette.muted;
    };
    path = ./config/scripts/rofi-app-menu.sh;
  };

  binShims = {
    rofi-app-menu = rofiAppMenu;
    shelllist-wifi = shelllistWifi;
    rofi-bluetooth-menu = rofiBluetoothMenu;
    rofi-clipboard-menu = rofiClipboardMenu;
    screenshot-annotate = screenshotAnnotate;
    nm-daemon = nmDaemon;
  };
in
{
  home.username = "laufan";
  home.homeDirectory = "/home/laufan";
  home.stateVersion = "26.05";

  # Everything in binShims is also a package; register each script once there.
  home.packages = lib.attrValues binShims ++ [
    hyprMonitorAuto
    shelllistPortalBrowser
    scratchpad
    tsReactQualityLens
    zenBrowser
    pkgs.affinity-v3
    # Track the latest nixpkgs-unstable build; the system startup updater keeps
    # this input current for Codex, Pi, and Claude.
    unstablePkgs.codex
  ] ++ (with pkgs; [
    ghostty
    hyprlandGuiutils
    waybar
    hyprlock
    hyprpaper
    swayosd
    qt5.qtwayland
    qt6.qtwayland
    wlogout
    btop
  ]);

  home.sessionVariables = {
    BROWSER = "zen";
    # Terminal editing defaults to nvim; Git is intentionally configured below
    # to use VS Code for commit messages and interactive operations.
    EDITOR = "nvim";
    VISUAL = "code --wait";
  } // sharedSessionVariables // {
    QT_QPA_PLATFORMTHEME = lib.mkForce sharedSessionVariables.QT_QPA_PLATFORMTHEME;
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
      name = fonts.ui;
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
      font-name = "${fonts.ui} ${theme.ui.fontSize}";
      document-font-name = "${fonts.ui} ${theme.ui.fontSize}";
      monospace-font-name = "${fonts.code} ${theme.ui.fontSize}";
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
        "application/xhtml+xml" = "zen.desktop";
        "x-scheme-handler/file" = "yazi.desktop";
        "x-scheme-handler/http" = "zen.desktop";
        "x-scheme-handler/https" = "zen.desktop";
      };
    };

    configFile = {
      # Override package-provided XDG autostart entries; Waybar and the custom
      # network/Bluetooth controls own these interfaces instead of tray applets.
      "autostart/blueman.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Hidden=true
      '';
      "autostart/nm-applet.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Hidden=true
      '';
      "hypr/hyprland.conf".text = hyprlandConfig;
      "hypr/hyprlock.conf".text = themeText (scriptWith
        { "@WALLPAPER@" = "${wallpaper}"; }
        ./config/hypr/hyprlock.conf);
      "hypr/hyprpaper.conf".text = scriptWith
        { "@WALLPAPER@" = "${wallpaper}"; }
        ./config/hypr/hyprpaper.conf;
      "waybar/config".text = builtins.readFile ./config/waybar/config.jsonc;
      "waybar/style.css".text = themeText (builtins.readFile ./config/waybar/style.css);
      "waybar/zen-workspace.svg".source = ./config/waybar/zen-workspace.svg;
      "waybar/vscode-workspace.svg".source = ./config/waybar/vscode-workspace.svg;
      "waybar/spotify-workspace.svg".source = ./config/waybar/spotify-workspace.svg;
      "waybar/scratchpad-workspace.svg".source = ./config/waybar/scratchpad-workspace.svg;
      "rofi/config.rasi".text = themeText (builtins.readFile ./config/rofi/config.rasi);
      "ghostty/config".text = themeText (builtins.readFile ./config/ghostty/config);
      "Code/User/settings.json".text = builtins.toJSON {
        "editor.fontFamily" = "'${fonts.code}', monospace";
        "editor.fontSize" = 18;
        "terminal.integrated.fontFamily" = "'${fonts.terminal}'";
        "window.zoomLevel" = 0.5;
        "chat.viewSessions.orientation" = "stacked";
      };
      "gtk-3.0/gtk.css".text = themeText (builtins.readFile ./config/gtk/gtk.css);
      "gtk-4.0/gtk.css".text = themeText (builtins.readFile ./config/gtk/gtk.css);
      "scratchpad/system-appearance.toml".text = themeText (builtins.readFile ./config/scratchpad/system-appearance.toml);
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
      # Keep Yazi on the active workspace instead of matching the regular
      # Ghostty-to-workspace-1 window rule.
      exec = "ghostty --class=com.laufan.yazi -e yazi %f";
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
      comment = "Open Shelllist's temporary captive-portal browser with a fallback HTTP probe";
      exec = "shelllist-captive-portal --manual --fallback";
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
    # Temporary compatibility shim while Shelllist migrates its command name.
    ".local/bin/nm-api".source = "${nmDaemon}/bin/nm-daemon";
    ".local/bin/pi" = {
      source = "${unstablePkgs.pi-coding-agent}/bin/pi";
      force = true;
    };
    ".pi/agent/extensions/recent-sessions-sidebar" = {
      source = ./config/pi/recent-sessions-sidebar;
      force = true;
    };
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

  services.network-manager-applet.enable = false;
  services.blueman-applet.enable = false;
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

  systemd.user.targets.hyprland-session = {
    Unit = {
      Description = "Hyprland compositor session";
      Documentation = [ "man:systemd.special(7)" ];
      BindsTo = [ "graphical-session.target" ];
      Wants = [ "graphical-session-pre.target" ];
      After = [ "graphical-session-pre.target" ];
      Before = [ "graphical-session.target" ];
    };
  };

  systemd.user.services = {
    # Mirror and enable the nm-daemon.service user unit installed by the package.
    # D-Bus activation can be added later as a fallback startup path.
    nm-daemon = {
      Unit = {
        Description = "nm-daemon NetworkManager user service";
        Documentation = [ "https://github.com/pmfleming/nm-daemon" ];
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${nmDaemon}/bin/nm-daemon daemon";
        Restart = "on-failure";
        RestartSec = "2s";
      };

      Install.WantedBy = [ "default.target" ];
    };

    hypr-monitor-auto = mkUserService
      "Hyprland monitor auto-switcher"
      "${hyprMonitorAuto}/bin/hypr-monitor-auto"
      "2s";

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
            run = "\${EDITOR:-nvim} \"$@\"";
            block = true;
          }
        ];
        open = [
          {
            run = ''xdg-open "$1"'';
            orphan = true;
          }
        ];
        # Satty replaced Swappy for screenshot, clipboard, and Yazi image
        # editing because Swappy does not provide post-capture cropping.
        satty = [
          {
            run = ''
              input="$1"
              case "$input" in
                *.png) output="$input" ;;
                *) output="''${input%.*}.edited.png" ;;
              esac
              exec satty \
                --filename "$input" \
                --output-filename "$output" \
                --resize smart \
                --early-exit \
                --actions-on-enter save-to-file
            '';
            orphan = true;
            desc = "Crop or annotate image in Satty";
          }
        ];
      };
      open = {
        prepend_rules = [
          { mime = "image/*"; use = "satty"; }
          { url = "*.html"; use = "open"; }
          { url = "*.htm"; use = "open"; }
          { mime = "text/html"; use = "open"; }
          { mime = "application/xhtml+xml"; use = "open"; }
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
          fg = palette.foreground;
          bg = palette.bg;
          bold = true;
          underline = true;
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
