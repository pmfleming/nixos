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
  inputPackage = input: name: input.packages.${system}.${name};
  hyprlandGuiutils = inputPackage inputs.hyprland-guiutils "default";
  nmDaemon = inputPackage inputs.nm-daemon "default";
  btDaemon = inputPackage inputs.bt-daemon "default";
  clipDaemon = inputPackage inputs.clip-daemon "default";
  appDaemon = inputPackage inputs.app-daemon "default";
  shelllist = inputPackage inputs.shelllist "default";
  shelllistPortalBrowser = inputPackage inputs.shelllist "captivePortalBrowser";
  scratchpad = inputPackage inputs.scratchpad "scratchpad-hyprland";
  tsReactQualityLens = inputPackage inputs.ts-react-quality-lens "default";
  zenBrowser = inputPackage inputs.zen-browser "default";

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
    SHELLLIST_MODE = "popover";
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
  uwsmApp = "${pkgs.uwsm}/bin/uwsm-app";

  mkUserService =
    {
      description,
      execStart,
      execStartPre ? [ ],
      after ? [ ],
      requires ? [ ],
      partOf ? [ ],
      environment ? { },
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
        Slice = "background-graphical.slice";
      }
      // lib.optionalAttrs (execStartPre != [ ]) {
        ExecStartPre = execStartPre;
      }
      // lib.optionalAttrs (environment != { }) {
        Environment = lib.mapAttrsToList (name: value: "${name}=${builtins.toString value}") environment;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
  mkScript = scriptLib.mkScriptFrom pkgs ./config/scripts;
  configPath = path: ./config + "/${path}";
  readConfig = path: builtins.readFile (configPath path);
  themedConfig = path: themeText (readConfig path);
  writableConfig = path: {
    source = config.lib.file.mkOutOfStoreSymlink "${machine.configDirectory}/config/${path}";
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
      "@SCRATCHPAD@" = "${scratchpad}/bin/scratchpad";
      "@UWSM_APP@" = uwsmApp;
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
      "@MONITOR_SCALE@" = theme.appearance.monitorScale;
    };
  };

  # After= only waits for ringboard-server's process to start. Probe the server
  # before launching clients so a stale socket from the previous session cannot
  # make the Wayland watcher fail and restart during login.
  ringboardWaitReady = pkgs.writeShellScript "wait-for-ringboard-server" ''
    for _ in {1..100}; do
      if ${pkgs.ringboard-wayland}/bin/ringboard debug stats >/dev/null 2>&1; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "ringboard server did not become ready within 10 seconds" >&2
    exit 1
  '';

  nwgDisplaysLua = mkScript {
    name = "nwg-displays-lua";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      hyprland
    ];
    replacements = {
      "@NWG_DISPLAYS@" = "${pkgs.nwg-displays}";
      "@MONITORS_LUA@" = "${machine.configDirectory}/config/hypr/monitors.lua";
      "@WORKSPACES_LUA@" = "${machine.configDirectory}/config/hypr/workspaces.lua";
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

in
{
  imports = [
    inputs.shelllist.homeManagerModules.default
    (import ./modules/home/yazi.nix {
      inherit
        palette
        scratchpad
        clipDaemon
        uwsmApp
        ;
    })
  ];

  programs.shelllist = {
    enable = true;
    package = shelllist;
    systemd = {
      target = "graphical-session.target";
      environment = lib.mapAttrs (_name: value: builtins.toString value) hyprlandSessionVariables;
    };
  };

  home = {
    inherit (machine) username homeDirectory;
    stateVersion = "26.05";

    packages = [
      appDaemon
      btDaemon
      clipDaemon
      nmDaemon
      screenshotAnnotate
      shelllistPortalBrowser
      hyprMonitorAuto
      nwgDisplaysLua
      scratchpad
      tsReactQualityLens
      zenBrowser
      pkgs.inkscape
      # The fast lane keeps this package current independently of other inputs.
      unstablePkgs.codex
    ]
    ++ (with pkgs; [
      ghostty
      hyprlandGuiutils
      hyprlock
      hyprpaper
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

    file = {
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
      "systemd/user/graphical-session.target.wants/nm-daemon.service".source =
        "${nmDaemon}/share/systemd/user/nm-daemon.service";
      "systemd/user/graphical-session.target.wants/bt-daemon.service".source =
        "${btDaemon}/share/systemd/user/bt-daemon.service";
      "systemd/user/nm-daemon.service.d/uwsm-session.conf".text = ''
        [Unit]
        PartOf=graphical-session.target

        [Service]
        Slice=background-graphical.slice
      '';
      "systemd/user/bt-daemon.service.d/uwsm-session.conf".text = ''
        [Unit]
        PartOf=graphical-session.target

        [Service]
        Slice=background-graphical.slice
      '';
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
      blueman-manager = {
        name = "Bluetooth Manager";
        genericName = "Bluetooth Manager";
        comment = "Configure Bluetooth devices";
        exec = "env GDK_BACKEND=x11 blueman-manager";
        icon = "blueman";
        categories = [
          "GTK"
          "GNOME"
          "Settings"
          "HardwareSettings"
        ];
        settings.StartupWMClass = ".blueman-manager-wrapped";
      };

      nwg-displays = {
        name = "Displays Settings";
        genericName = "Output configuration utility";
        comment = "Configure monitor layouts and write the Lua-compatible Hyprland layout";
        exec = "env GDK_BACKEND=x11 ${nwgDisplaysLua}/bin/nwg-displays-lua";
        icon = "nwg-displays";
        categories = [
          "Settings"
          "DesktopSettings"
        ];
        settings.StartupWMClass = "Nwg-displays";
      };

      qv4l2 = {
        name = "Qt V4L2 test Utility";
        comment = "Allow testing Video4Linux devices";
        exec = "env QT_QPA_PLATFORM=xcb QT_OPENGL=software qv4l2";
        icon = "qv4l2";
        categories = [ "AudioVideo" ];
        settings.StartupWMClass = "qv4l2";
      };

      qvidcap = {
        name = "Qt V4L2 video capture utility";
        comment = "Viewer for video capture";
        exec = "env QT_QPA_PLATFORM=xcb QT_OPENGL=software qvidcap";
        icon = "qvidcap";
        categories = [ "AudioVideo" ];
        settings.StartupWMClass = "qvidcap";
      };

      cups = {
        name = "Manage Printing";
        comment = "Open the CUPS web interface in the default browser";
        exec = "xdg-open http://localhost:631/";
        icon = "cups";
        categories = [
          "System"
          "Settings"
          "Printing"
        ];
        settings."X-Shelllist-LaunchOnly" = "true";
      };

      nixos-manual = {
        name = "NixOS Manual";
        genericName = "System Manual";
        comment = "View NixOS documentation in the default browser";
        exec = "nixos-help";
        icon = "nix-snowflake";
        categories = [ "System" ];
        settings."X-Shelllist-LaunchOnly" = "true";
      };

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
        settings.StartupWMClass = "shelllist-captive-portal";
      };
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || ${uwsmApp} -s s -- hyprlock";
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

  systemd.user.services = {
    shelllist.Service.Slice = "session-graphical.slice";
    bar-daemon.Service.Slice = "session-graphical.slice";

    hyprpaper = mkUserService {
      description = "Hyprland wallpaper service";
      execStart = "${pkgs.hyprpaper}/bin/hyprpaper";
      restart = "on-failure";
    };

    hyprpolkitagent = mkUserService {
      description = "Hyprland PolicyKit authentication agent";
      execStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      restart = "on-failure";
    };

    hypr-monitor-auto = mkUserService {
      description = "Hyprland monitor auto-switcher";
      execStart = "${hyprMonitorAuto}/bin/hypr-monitor-auto";
    };

    app-daemon = mkUserService {
      description = "Shelllist application catalog and activation service";
      execStart = "${appDaemon}/bin/app-daemon daemon";
      restart = "on-failure";
    };

    ringboard-server = mkUserService {
      description = "Ringboard clipboard history server";
      execStart = "${pkgs.ringboard-wayland}/bin/ringboard-server";
    };

    ringboard-wayland = mkUserService {
      description = "Ringboard Wayland clipboard watcher";
      execStart = "${pkgs.ringboard-wayland}/bin/ringboard-wayland";
      execStartPre = [ ringboardWaitReady ];
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
