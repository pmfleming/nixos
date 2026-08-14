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
  clipDaemon = inputs.clip-daemon.packages.${system}.default;
  appDaemon = inputs.app-daemon.packages.${system}.default;
  shelllistWifi = inputs.shelllist.packages.${system}.default;
  shelllistBluetooth = inputs.shelllist.packages.${system}.bluetooth;
  shelllistClipboard = inputs.shelllist.packages.${system}.clipboard;
  shelllistLauncher = inputs.shelllist.packages.${system}.launcher;
  shelllistPortalBrowser = inputs.shelllist.packages.${system}.captivePortalBrowser;
  scratchpad = inputs.scratchpad.packages.${system}.scratchpad-hyprland;
  tsReactQualityLens = inputs.ts-react-quality-lens.packages.${system}.default;
  zenBrowser = inputs.zen-browser.packages.${system}.default;
  waybar = pkgs.waybar.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./config/patches/waybar-hyprland-lua-workspaces.patch
    ];
  });

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
    SHELLLIST_CLIPBOARD_MODE = "popover";
    SHELLLIST_LAUNCHER_MODE = "popover";
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
    lib.mapAttrsToList (
      name: value: "hl.env(${builtins.toJSON name}, ${builtins.toJSON (builtins.toString value)})"
    ) hyprlandEnvVariables
  );

  mkUserService =
    {
      description,
      execStart,
      after ? [ ],
      requires ? [ ],
      partOf ? [ ],
      environment ? [ ],
      restart ? "always",
      restartSec ? "2s",
    }:
    {
      Unit = {
        Description = description;
        After = [ "graphical-session.target" ] ++ after;
        Requires = requires;
        PartOf = [ "graphical-session.target" ] ++ partOf;
      };
      Service = {
        ExecStart = execStart;
        Restart = restart;
        RestartSec = restartSec;
      }
      // lib.optionalAttrs (environment != [ ]) {
        Environment = environment;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

  binShim =
    name: drv:
    lib.nameValuePair ".local/bin/${name}" {
      source = "${drv}/bin/${name}";
    };

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
  mkScript = scriptLib.mkScriptFrom pkgs ./config/scripts;
  configPath = path: ./config + "/${path}";
  readConfig = path: builtins.readFile (configPath path);
  themedConfig = path: themeText (readConfig path);
  writableConfig = path: {
    source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/config/${path}";
    force = true;
  };
  hiddenAutostart.text = ''
    [Desktop Entry]
    Type=Application
    Hidden=true
  '';

  hyprlandConfig = themeText (
    scriptWith {
      "@HYPRLAND_ENV@" = hyprlandEnvConfig;
      "@HYPRPOLKITAGENT@" = "${pkgs.hyprpolkitagent}";
      "@SCRATCHPAD@" = "${scratchpad}/bin/scratchpad";
      "@DBUS_UPDATE_ACTIVATION_ENVIRONMENT@" = "${pkgs.dbus}/bin/dbus-update-activation-environment";
      "@SYSTEMCTL@" = "${pkgs.systemd}/bin/systemctl";
    } ./config/hypr/hyprland.lua
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
      "@WAYBAR@" = "${waybar}/bin/waybar";
      "@MONITOR_SCALE@" = theme.appearance.monitorScale;
    };
  };

  nwgDisplaysLua = mkScript {
    name = "nwg-displays-lua";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      hyprland
    ];
    replacements = {
      "@NWG_DISPLAYS@" = "${pkgs.nwg-displays}";
      "@MONITORS_LUA@" = "/etc/nixos/config/hypr/monitors.lua";
      "@WORKSPACES_LUA@" = "/etc/nixos/config/hypr/workspaces.lua";
    };
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
  };

  binShims = {
    shelllist-wifi = shelllistWifi;
    shelllist-bluetooth = shelllistBluetooth;
    shelllist-clipboard = shelllistClipboard;
    shelllist-launcher = shelllistLauncher;
    screenshot-annotate = screenshotAnnotate;
    nm-daemon = nmDaemon;
    bt-daemon = btDaemon;
    clip-daemon = clipDaemon;
    app-daemon = appDaemon;
  };
in
{
  imports = [
    (import ./modules/home/yazi.nix { inherit palette scratchpad clipDaemon; })
  ];

  home = {
    inherit (machine) username homeDirectory;
    stateVersion = "26.05";

    # Everything in binShims is also a package; register each script once there.
    packages =
      lib.attrValues binShims
      ++ [
        hyprMonitorAuto
        nwgDisplaysLua
        shelllistPortalBrowser
        scratchpad
        tsReactQualityLens
        zenBrowser
        pkgs.inkscape
        waybar
        # The fast update lane keeps this nixpkgs-unstable package current without
        # the quarantine applied to the rest of the flake inputs.
        unstablePkgs.codex
      ]
      ++ (with pkgs; [
        ghostty
        hyprlandGuiutils
        hyprlock
        hyprpaper
        swayosd
        qt5.qtwayland
        qt6.qtwayland
        wlogout
        btop
      ]);

    sessionVariables = {
      BROWSER = "zen";
      # Terminal editing defaults to nvim; Git is intentionally configured below
      # to use VS Code for commit messages and interactive operations.
      EDITOR = "nvim";
      VISUAL = "code --wait";
    };
    sessionPath = [ "$HOME/.local/bin" ];

    pointerCursor = {
      name = theme.appearance.cursorTheme;
      package = pkgs.bibata-cursors;
      size = theme.appearance.cursorSize;
      gtk.enable = true;
      x11.enable = true;
    };

    # User-level shims keep interactive launchers current before the next system switch.
    file = lib.mapAttrs' binShim binShims // {
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
  };

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
      "autostart/blueman.desktop" = hiddenAutostart;
      "autostart/nm-applet.desktop" = hiddenAutostart;
      # Install and enable the package-owned units instead of cloning their definitions.
      # Direct unit links keep them discoverable by systemctl; wants links enable them.
      "systemd/user/nm-daemon.service".source = "${nmDaemon}/share/systemd/user/nm-daemon.service";
      "systemd/user/bt-daemon.service".source = "${btDaemon}/share/systemd/user/bt-daemon.service";
      "systemd/user/default.target.wants/nm-daemon.service".source =
        "${nmDaemon}/share/systemd/user/nm-daemon.service";
      "systemd/user/default.target.wants/bt-daemon.service".source =
        "${btDaemon}/share/systemd/user/bt-daemon.service";
      "hypr/hyprland.lua".text = hyprlandConfig;
      # Keep generated layouts writable and version-controlled.
      "hypr/monitors.lua" = writableConfig "hypr/monitors.lua";
      "hypr/workspaces.lua" = writableConfig "hypr/workspaces.lua";
      "hypr/hyprlock.conf".text = themeText (
        scriptWith { "@WALLPAPER@" = "${wallpaper}"; } (configPath "hypr/hyprlock.conf")
      );
      "hypr/hyprpaper.conf".text = scriptWith {
        "@WALLPAPER@" = "${wallpaper}";
      } (configPath "hypr/hyprpaper.conf");
      "waybar/config".text = readConfig "waybar/config.jsonc";
      "waybar/style.css".text = themedConfig "waybar/style.css";
      "waybar/zen-workspace.svg".source = ./config/waybar/zen-workspace.svg;
      "waybar/vscode-workspace.svg".source = ./config/waybar/vscode-workspace.svg;
      "waybar/spotify-workspace.svg".source = ./config/waybar/spotify-workspace.svg;
      "waybar/scratchpad-workspace.svg".source = ./config/waybar/scratchpad-workspace.svg;
      "ghostty/config".text = themedConfig "ghostty/config";
      # VS Code writes settings from its UI, so keep this as a writable,
      # version-controlled out-of-store file rather than a Nix store symlink.
      "Code/User/settings.json" = writableConfig "vscode/settings.json";
      "gtk-3.0/gtk.css".text = themedConfig "gtk/gtk.css";
      "gtk-4.0/gtk.css".text = themedConfig "gtk/gtk.css";
      "scratchpad/system-appearance.toml".text = themedConfig "scratchpad/system-appearance.toml";
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
      "swaync/config.json".source = configPath "swaync/config.json";
      "swaync/style.css".text = themedConfig "swaync/style.css";
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
        mimeType = [
          "inode/directory"
        ];
        categories = [
          "System"
          "FileManager"
        ];
        settings.StartupWMClass = "com.laufan.yazi";
      };

      pi = {
        name = "Pi";
        genericName = "AI Coding Assistant";
        comment = "Open Pi coding assistant";
        exec = "ghostty --class=com.laufan.pi -e pi";
        icon = "${./assets/pi-logo-on-dark.svg}";
        categories = [
          "Development"
          "Utility"
        ];
        settings.StartupWMClass = "com.laufan.pi";
      };

      captive-portal-browser = {
        name = "Captive Portal Browser";
        genericName = "Captive Portal Browser";
        comment = "Open Shelllist's temporary captive-portal browser with a fallback HTTP probe";
        exec = "shelllist-captive-portal --manual --fallback";
        categories = [
          "Network"
          "WebBrowser"
        ];
      };
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "hyprctl dispatch 'hl.dsp.dpms(\"on\")'";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 420;
          on-timeout = "hyprctl dispatch 'hl.dsp.dpms(\"off\")'";
          on-resume = "hyprctl dispatch 'hl.dsp.dpms(\"on\")'";
        }
        {
          timeout = 1800;
          on-timeout = "systemctl suspend";
        }
      ];
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
      hypr-monitor-auto = mkUserService {
        description = "Hyprland monitor auto-switcher";
        execStart = "${hyprMonitorAuto}/bin/hypr-monitor-auto";
      };

      app-daemon = mkUserService {
        description = "Shelllist application catalog and activation service";
        execStart = "${appDaemon}/bin/app-daemon daemon";
        restart = "on-failure";
      };

      shelllist-launcher = mkUserService {
        description = "Shelllist application launcher frontend";
        execStart = "${shelllistLauncher}/bin/shelllist-launcher foreground";
        after = [ "app-daemon.service" ];
        requires = [ "app-daemon.service" ];
        environment = lib.mapAttrsToList (
          name: value: "${name}=${builtins.toString value}"
        ) hyprlandSessionVariables;
        restart = "on-failure";
      };

      shelllist-bluetooth = mkUserService {
        description = "Shelllist Bluetooth prompt frontend";
        execStart = "${shelllistBluetooth}/bin/shelllist-bluetooth foreground";
        after = [ "bt-daemon.service" ];
        environment = lib.mapAttrsToList (name: value: "${name}=${builtins.toString value}") (
          lib.removeAttrs hyprlandSessionVariables [ "SHELLLIST_WIFI_MODE" ]
          // {
            SHELLLIST_BLUETOOTH_MODE = "popover";
          }
        );
        restart = "on-failure";
      };

      ringboard-server = mkUserService {
        description = "Ringboard clipboard history server";
        execStart = "${pkgs.ringboard-wayland}/bin/ringboard-server";
      };

      ringboard-wayland = mkUserService {
        description = "Ringboard Wayland clipboard watcher";
        execStart = "${pkgs.ringboard-wayland}/bin/ringboard-wayland";
        after = [ "ringboard-server.service" ];
        requires = [ "ringboard-server.service" ];
        partOf = [ "ringboard-server.service" ];
      };

      clip-daemon = mkUserService {
        description = "Shelllist clipboard policy service";
        execStart = "${clipDaemon}/bin/clip-daemon daemon";
        after = [
          "ringboard-server.service"
          "ringboard-wayland.service"
        ];
        requires = [
          "ringboard-server.service"
          "ringboard-wayland.service"
        ];
        partOf = [
          "ringboard-server.service"
          "ringboard-wayland.service"
        ];
      };
    };
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
