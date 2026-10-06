{
  pkgs,
}:

let
  v4lEntry = command: name: comment: {
    inherit name comment;
    exec = "env QT_QPA_PLATFORM=xcb QT_OPENGL=software ${command}";
    icon = command;
    categories = [ "AudioVideo" ];
    settings.StartupWMClass = command;
  };
  shelllistOnly = entry: entry // { settings."X-Shelllist-LaunchOnly" = "true"; };
  chromeWebApp =
    {
      id,
      name,
      genericName,
      comment,
      url,
      icon,
      forceDark ? false,
    }:
    let
      launcher = pkgs.writeShellApplication {
        name = id;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.google-chrome
        ];
        text = ''
          umask 077
          data_home="''${XDG_DATA_HOME:-$HOME/.local/share}"
          profile="$data_home/chrome-web-apps/${id}"
          mkdir -p -- "$profile"
          # bar-daemon reads these labels from the D-Bus owner's environment.
          export SHELLLIST_MEDIA_IDENTITY=${pkgs.lib.escapeShellArg name}
          export SHELLLIST_MEDIA_DESKTOP_ENTRY=${pkgs.lib.escapeShellArg id}
          export CHROME_DESKTOP=${pkgs.lib.escapeShellArg "${id}.desktop"}
          exec google-chrome-stable \
            --user-data-dir="$profile" \
            --class=${pkgs.lib.escapeShellArg id} \
            --no-first-run --no-default-browser-check \
            ${pkgs.lib.optionalString forceDark "--force-dark-mode --enable-features=WebContentsForceDark"} \
            --app=${pkgs.lib.escapeShellArg url}
        '';
      };
    in
    {
      inherit
        name
        genericName
        comment
        icon
        ;
      exec = "${launcher}/bin/${id}";
      categories = [
        "AudioVideo"
        "Audio"
        "Player"
      ];
      settings.StartupWMClass = id;
    };
in
{
  "com.laufan.audible" = chromeWebApp {
    id = "com.laufan.audible";
    name = "Audible";
    genericName = "Audiobook Player";
    comment = "Listen to audiobooks with Audible";
    url = "https://www.audible.co.uk/library/titles";
    icon = "com.laufan.audible";
    forceDark = true;
  };

  "com.laufan.pocketcasts" = chromeWebApp {
    id = "com.laufan.pocketcasts";
    name = "Pocket Casts";
    genericName = "Podcast Player";
    comment = "Listen to podcasts with Pocket Casts";
    url = "https://play.pocketcasts.com/";
    icon = "com.laufan.pocketcasts";
  };

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

  shelllist-displays = {
    name = "Displays Settings";
    genericName = "Output configuration utility";
    comment = "Configure daemon-owned display layouts with automatic preview rollback";
    exec = "shelllist open displays";
    icon = "video-display";
    categories = [
      "Settings"
      "DesktopSettings"
    ];
  };

  qv4l2 = v4lEntry "qv4l2" "Qt V4L2 test Utility" "Allow testing Video4Linux devices";
  qvidcap = v4lEntry "qvidcap" "Qt V4L2 video capture utility" "Viewer for video capture";

  cups = shelllistOnly {
    name = "Manage Printing";
    comment = "Open the CUPS web interface in the default browser";
    exec = "xdg-open http://localhost:631/";
    icon = "cups";
    categories = [
      "System"
      "Settings"
      "Printing"
    ];
  };

  nixos-manual = shelllistOnly {
    name = "NixOS Manual";
    genericName = "System Manual";
    comment = "View NixOS documentation in the default browser";
    exec = "nixos-help";
    icon = "nix-snowflake";
    categories = [ "System" ];
  };

  yazi = {
    name = "Yazi";
    genericName = "Terminal File Manager";
    comment = "Browse files in Yazi";
    # Keep Yazi on the active workspace instead of matching the regular
    # Ghostty-to-workspace-1 window rule.
    exec = "ghostty --class=com.laufan.yazi -e yazi %f";
    icon = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/legacy/system-file-manager-symbolic.svg";
    mimeType = [ "inode/directory" ];
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
    icon = "${../../assets/pi-logo-on-dark.svg}";
    categories = [
      "Development"
      "Utility"
    ];
    settings.StartupWMClass = "com.laufan.pi";
  };

  captive-portal-browser = {
    name = "Captive Portal Browser";
    genericName = "Captive Portal Browser";
    # Browser launches now require a claimed daemon intent. Enter the Wi-Fi UI
    # rather than bypassing that transaction through the retired shell helper.
    comment = "Open Wi-Fi controls to sign in to a captive portal";
    exec = "shelllist open wifi";
    categories = [
      "Network"
      "WebBrowser"
    ];
    settings.StartupWMClass = "shelllist-captive-portal";
  };
}
