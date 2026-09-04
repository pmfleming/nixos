{
  nwgDisplaysLua,
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
in
{
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
    comment = "Open Shelllist's temporary captive-portal browser with a fallback HTTP probe";
    exec = "shelllist-captive-portal --manual --fallback";
    categories = [
      "Network"
      "WebBrowser"
    ];
    settings.StartupWMClass = "shelllist-captive-portal";
  };
}
