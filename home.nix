{
  config,
  inputs,
  lib,
  machine,
  pkgs,
  unstablePkgs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  hyprlandGuiutils = inputs.hyprland-guiutils.packages.${system}.default;
  nmDaemon = inputs.nm-daemon.packages.${system}.default;
  btDaemon = inputs.bt-daemon.packages.${system}.default;
  shelllistWifi = inputs.shelllist.packages.${system}.default;
  shelllistBluetooth = inputs.shelllist.packages.${system}.bluetooth;
  shelllistPortalBrowser = inputs.shelllist.packages.${system}.captivePortalBrowser;
  scratchpad = inputs.scratchpad.packages.${system}.scratchpad-hyprland;
  tsReactQualityLens = inputs.ts-react-quality-lens.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;

  theme = import ./theme.nix { inherit lib; };
  inherit (theme)
    palette
    fonts
    themeText
    wallpaper
    ;

  hyprlandSessionVariables = {
    GTK_THEME = theme.appearance.gtkThemeEnv;
    QT_QPA_PLATFORM = "wayland;xcb";
    QT_QPA_PLATFORMTHEME = theme.appearance.qtPlatformTheme;
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

  hyprlandEnvVariables = hyprlandSessionVariables // {
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

  binShim =
    drv: name:
    lib.nameValuePair ".local/bin/${name}" {
      source = "${drv}/bin/${name}";
    };

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
  mkScript = scriptLib.mkShellApplication pkgs;

  hyprlandConfig = themeText (
    scriptWith {
      "@HYPRLAND_ENV@" = hyprlandEnvConfig;
      "@HYPRPOLKITAGENT@" = "${pkgs.hyprpolkitagent}";
      "@SCRATCHPAD@" = "${scratchpad}/bin/scratchpad";
      "@DBUS_UPDATE_ACTIVATION_ENVIRONMENT@" = "${pkgs.dbus}/bin/dbus-update-activation-environment";
      "@SYSTEMCTL@" = "${pkgs.systemd}/bin/systemctl";
    } ./config/hypr/hyprland.conf
  );

  hyprMonitorAuto = mkScript {
    name = "hypr-monitor-auto";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      hyprland
      procps
      socat
    ];
    replacements = {
      "@WAYBAR@" = "${pkgs.waybar}/bin/waybar";
      "@MONITOR_SCALE@" = theme.appearance.monitorScale;
    };
    path = ./config/scripts/hypr-monitor-auto.sh;
  };

  rofiScriptHelpers = pkgs.writeText "rofi-helpers.sh" (
    scriptWith { } ./config/scripts/rofi-helpers.sh
  );
  rofiHelperReplacement = {
    "@ROFI_SCRIPT_HELPERS@" = "${rofiScriptHelpers}";
  };
  mkRofiScript =
    attrs:
    mkScript (
      attrs
      // {
        replacements = rofiHelperReplacement // (attrs.replacements or { });
      }
    );

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

  mkCliphistWatcher =
    { description, mime }:
    mkUserService description
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
    shelllist-bluetooth = shelllistBluetooth;
    rofi-bluetooth-menu = rofiBluetoothMenu;
    rofi-clipboard-menu = rofiClipboardMenu;
    screenshot-annotate = screenshotAnnotate;
    nm-daemon = nmDaemon;
    bt-daemon = btDaemon;
  };
in
{
  imports = [
    (import ./modules/home/yazi.nix { inherit palette; })
  ];

  home.username = machine.username;
  home.homeDirectory = machine.homeDirectory;
  home.stateVersion = "26.05";

  # Everything in binShims is also a package; register each script once there.
  home.packages =
    lib.attrValues binShims
    ++ [
      hyprMonitorAuto
      shelllistPortalBrowser
      scratchpad
      tsReactQualityLens
      zenBrowser
      pkgs.affinity-v3
      # Track the latest nixpkgs-unstable build; the system startup updater keeps
      # this input current for Codex, Pi, and Claude.
      unstablePkgs.codex
    ]
    ++ (with pkgs; [
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
    platformTheme.name = theme.appearance.qtPlatformTheme;
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
    # bt-daemon owns the single BlueZ OBEX authorization-agent slot while
    # Blueman remains available for its other stabilization workflows.
    "org/blueman/general".plugin-list = [ "!TransferService" ];
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
      # Install and enable the package-owned units instead of cloning their definitions.
      # Direct unit links keep them discoverable by systemctl; wants links enable them.
      "systemd/user/nm-daemon.service".source = "${nmDaemon}/share/systemd/user/nm-daemon.service";
      "systemd/user/bt-daemon.service".source = "${btDaemon}/share/systemd/user/bt-daemon.service";
      "systemd/user/default.target.wants/nm-daemon.service".source =
        "${nmDaemon}/share/systemd/user/nm-daemon.service";
      "systemd/user/default.target.wants/bt-daemon.service".source =
        "${btDaemon}/share/systemd/user/bt-daemon.service";
      "hypr/hyprland.conf".text = hyprlandConfig;
      # Keep nwg-displays output version-controlled while allowing it to update
      # the files through Home Manager's out-of-store links.
      "hypr/monitors.conf" = {
        source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/config/hypr/monitors.conf";
        force = true;
      };
      "hypr/workspaces.conf" = {
        source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/config/hypr/workspaces.conf";
        force = true;
      };
      "hypr/hyprlock.conf".text = themeText (
        scriptWith { "@WALLPAPER@" = "${wallpaper}"; } ./config/hypr/hyprlock.conf
      );
      "hypr/hyprpaper.conf".text = scriptWith {
        "@WALLPAPER@" = "${wallpaper}";
      } ./config/hypr/hyprpaper.conf;
      "waybar/config".text = builtins.readFile ./config/waybar/config.jsonc;
      "waybar/style.css".text = themeText (builtins.readFile ./config/waybar/style.css);
      "waybar/zen-workspace.svg".source = ./config/waybar/zen-workspace.svg;
      "waybar/vscode-workspace.svg".source = ./config/waybar/vscode-workspace.svg;
      "waybar/spotify-workspace.svg".source = ./config/waybar/spotify-workspace.svg;
      "waybar/scratchpad-workspace.svg".source = ./config/waybar/scratchpad-workspace.svg;
      "rofi/config.rasi".text = themeText (builtins.readFile ./config/rofi/config.rasi);
      "ghostty/config".text = themeText (builtins.readFile ./config/ghostty/config);
      # VS Code writes settings from its UI, so keep this as a writable,
      # version-controlled out-of-store file rather than a Nix store symlink.
      "Code/User/settings.json" = {
        source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/config/vscode/settings.json";
        force = true;
      };
      "gtk-3.0/gtk.css".text = themeText (builtins.readFile ./config/gtk/gtk.css);
      "gtk-4.0/gtk.css".text = themeText (builtins.readFile ./config/gtk/gtk.css);
      "scratchpad/system-appearance.toml".text = themeText (
        builtins.readFile ./config/scratchpad/system-appearance.toml
      );
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

    desktopEntries = {
      yazi = {
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

      pi = {
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

      captive-portal-browser = {
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
  };

  # User-level shims keep interactive launchers current even before the next
  # root-level NixOS profile switch updates /etc/profiles/per-user.
  home.file = lib.mapAttrs' (name: drv: binShim drv name) binShims // {
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

  services = {
    network-manager-applet.enable = false;
    blueman-applet.enable = false;
    poweralertd.enable = false;

    hypridle = {
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
  };

  systemd.user = {
    targets.hyprland-session = {
      Unit = {
        Description = "Hyprland compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
        Before = [ "graphical-session.target" ];
      };
    };

    services = {
      hypr-monitor-auto =
        mkUserService "Hyprland monitor auto-switcher" "${hyprMonitorAuto}/bin/hypr-monitor-auto"
          "2s";

      wl-clip-persist =
        mkUserService "Keep the regular Wayland clipboard available after source apps exit"
          "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard regular"
          "2s";

      shelllist-bluetooth = {
        Unit = {
          Description = "Shelllist Bluetooth prompt frontend";
          After = [
            "graphical-session.target"
            "bt-daemon.service"
          ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${shelllistBluetooth}/bin/shelllist-bluetooth foreground";
          Restart = "on-failure";
          RestartSec = "2s";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    }
    // lib.mapAttrs (_: mkCliphistWatcher) cliphistWatchers;
  };

  programs = {
    bash.enable = true;

    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    git = {
      enable = true;
      settings = {
        user = {
          name = "Paul Fleming";
          email = "67100074+pmfleming@users.noreply.github.com";
        };
        core.editor = "code --wait";
      };
    };

    home-manager.enable = true;
  };
}
