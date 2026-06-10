{ lib, ... }:

{
  hardware.bluetooth.enable = lib.mkForce false;
  services.blueman.enable = lib.mkForce false;
  services.openssh.enable = lib.mkForce true;
  services.power-profiles-daemon.enable = lib.mkForce false;
  networking.firewall.allowedTCPPorts = [ 22 ];

  image.modules.hyperv = {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
    virtualisation.diskSize = 64 * 1024;
    image.fileName = "nixos-hyperv.vhdx";
    environment.etc."nixos".source = ../.;
    users.users.laufan.initialPassword = "nixos";

    fileSystems."/" = lib.mkForce {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
    };
    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
    };
  };
}
