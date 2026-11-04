{
  config,
  inputs,
  lib,
  machine,
  pkgs,
  unstablePkgs,
  vendorAiTools,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  inputPackage = input: name: input.packages.${system}.${name};
  hyprlandGuiutils = inputPackage inputs.hyprland-guiutils "default";
  scratchpad = inputPackage inputs.scratchpad "scratchpad-hyprland";
  tsReactQualityLens = inputPackage inputs.ts-react-quality-lens "default";
  zenBrowser = inputPackage inputs.zen-browser "default";
  theme = import ./theme.nix;
  inherit (theme)
    palette
    fonts
    themeText
    wallpaper
    ;

  cursor = {
    name = theme.appearance.cursorTheme;
    package = pkgs.bibata-cursors;
    size = theme.appearance.cursorSize;
  };

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
  # Copy standalone assets independently, not as references into the whole flake.
  storeFile = path: builtins.path { inherit path; };

  scriptLib = import ./lib/scripts.nix;
  scriptWith = scriptLib.withPlaceholders;
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
      "@SCRATCHPAD@" = "${scratchpad}/bin/scratchpad";
      "@UWSM_APP@" = uwsmApp;
    } ./config/hypr/hyprland.lua
  );

in
{
  imports = [
    ./modules/home/session.nix
    ./modules/home/file-associations.nix
    (import ./modules/home/yazi.nix {
      inherit
        palette
        scratchpad
        uwsmApp
        ;
      clipDaemon = inputPackage inputs.clip-daemon "default";
    })
  ];

  home = {
    inherit (machine) username homeDirectory;
    stateVersion = "26.05";

    packages = [
      scratchpad
      tsReactQualityLens
      zenBrowser
      pkgs.inkscape
      # Bootstrap fallback. Stable launchers prefer each checked vendor profile,
      # then the legacy shared profile, then these immutable system packages.
      unstablePkgs.codex
      unstablePkgs.antigravity-cli
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
      "${vendorAiTools.launchers}/bin"
      "$HOME/.local/bin"
    ];

    pointerCursor = cursor // {
      gtk.enable = true;
      x11.enable = true;
    };

    # Keep sibling lib/ imports in one store source. Managed files use Home
    # Manager's normal collision checks, not unconditional force-overwrite.
    file =
      lib.listToAttrs (
        map
          (name: {
            name = ".pi/agent/extensions/${name}";
            value.source = "${./config/pi}/${name}";
          })
          [
            "recent-sessions-sidebar"
            "worker-dashboard"
            "lib"
            "instances"
          ]
      )
      // {
        ".local/bin/pi-instances" = {
          source = storeFile ./config/scripts/pi-instances.sh;
          executable = true;
        };
      };
  };

  gtk = {
    enable = true;
    theme.name = theme.appearance.gtkTheme;
    iconTheme.name = theme.appearance.iconTheme;
    cursorTheme = cursor;
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
    configFile = {
      # Shelllist owns these interfaces instead of package-provided tray applets.
      "autostart/blueman.desktop" = hiddenAutostart;
      "autostart/nm-applet.desktop" = hiddenAutostart;
      # UWSM sources this before starting the compositor and exports the values
      # to the systemd and D-Bus activation environments for the whole session.
      "uwsm/env".text = uwsmEnvConfig;
      # Compositor policy uses the shared theme and explicit executable paths.
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
    };

    # Match the desktop IDs exposed by the isolated players over MPRIS so the
    # launcher and media chooser resolve the same locally installed app icons.
    dataFile = {
      "icons/hicolor/192x192/apps/com.laufan.audible.png".source = storeFile ./assets/audible.png;
      "icons/hicolor/192x192/apps/com.laufan.pocketcasts.png".source = storeFile ./assets/pocketcasts.png;
    };

    desktopEntries = import ./modules/home/desktop-entries.nix {
      inherit pkgs;
      inherit (machine) homeDirectory;
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
