{ ... }:

{
  services.xserver = {
    enable = true;
    desktopManager.xfce.enable = true;
  };

  services.xrdp = {
    enable = true;
    defaultWindowManager = "xfce4-session";
    openFirewall = true;
  };
}
