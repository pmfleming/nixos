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

  uwsmEnvironment = {
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
    XCURSOR_SIZE = builtins.toString theme.appearance.cursorSize;
    HYPRCURSOR_SIZE = builtins.toString theme.appearance.cursorSize;
    NIXOS_OZONE_WL = "1";
  };

  uwsmEnvConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: "export ${name}=${lib.escapeShellArg (builtins.toString value)}"
    ) uwsmEnvironment
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
  daemonUnitOverride.text = ''
    [Unit]
    PartOf=graphical-session.target

    [Service]
    Slice=background-graphical.slice
  '';
  packagedUserService = name: package: {
    "systemd/user/${name}.service".source = "${package}/share/systemd/user/${name}.service";
    "systemd/user/graphical-session.target.wants/${name}.service".source =
      "${package}/share/systemd/user/${name}.service";
    "systemd/user/${name}.service.d/uwsm-session.conf" = daemonUnitOverride;
  };
  packagedUserServices =
    packagedUserService "nm-daemon" nmDaemon // packagedUserService "bt-daemon" btDaemon;

  hyprlandConfig = themeText (
    scriptWith {
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
      util-linux
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
    systemd.target = "graphical-session.target";
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
      # Bootstrap fallback; /var/lib/nixos-ai-tools/current/bin shadows it
      # after the independent frequently updated profile has completed once.
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
    sessionPath = [
      "/var/lib/nixos-ai-tools/current/bin"
      "$HOME/.local/bin"
    ];

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

    configFile = packagedUserServices // {
      # Override package-provided XDG autostart entries; Waybar and the custom
      # network/Bluetooth controls own these interfaces instead of tray applets.
      "autostart/blueman.desktop" = hiddenAutostart;
      "autostart/nm-applet.desktop" = hiddenAutostart;
      # UWSM sources this before starting the compositor and exports the values
      # to the systemd and D-Bus activation environments for the whole session.
      "uwsm/env".text = uwsmEnvConfig;
      # Link and enable package-owned units instead of cloning their definitions.
      "hypr/hyprland.lua".text = hyprlandConfig;
      "bar-daemon/activity.json".text = builtins.toJSON {
        weather_locations = [
          {
            id = "home";
            location = "Amsterdam";
            home = true;
            latitude = 52.3676;
            longitude = 4.9041;
            timezone = "Europe/Amsterdam";
          }
          {
            id = "dublin";
            location = "Dublin";
            latitude = 53.3498;
            longitude = -6.2603;
            timezone = "Europe/Dublin";
          }
          {
            id = "oklahoma-city";
            location = "Oklahoma City";
            latitude = 35.4676;
            longitude = -97.5164;
            timezone = "America/Chicago";
          }
          {
            id = "hangzhou";
            location = "Hangzhou";
            latitude = 30.2741;
            longitude = 120.1551;
            timezone = "Asia/Shanghai";
          }
          {
            id = "taipei";
            location = "Taipei";
            latitude = 25.033;
            longitude = 121.5654;
            timezone = "Asia/Taipei";
          }
        ];
      };
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

    desktopEntries = import ./modules/home/desktop-entries.nix { inherit nwgDisplaysLua pkgs; };
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

  # Keep activation bounded so a newly restarted graphical service that crashes
  # makes the rebuild fail instead of silently disappearing. Leave enough
  # headroom for unit-stop and sd-switch D-Bus bookkeeping.
  systemd.user.servicesStartTimeoutMs = 60000;

  systemd.user.services = {
    shelllist.Service = {
      Slice = "session-graphical.slice";
      TimeoutStopSec = "5s";
    };
    # A blocked PipeWire worker can prevent bar-daemon's Tokio runtime from
    # completing shutdown after SIGTERM. Do not let that strand Home Manager's
    # unit transaction and leave Shelllist stopped after a generation switch.
    bar-daemon.Service = {
      Slice = "session-graphical.slice";
      TimeoutStopSec = "5s";
    };

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
