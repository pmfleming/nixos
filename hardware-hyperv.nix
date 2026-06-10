# Hyper-V VM hardware profile.
#
# This profile assumes the installer creates:
# - an ext4 root filesystem labeled "nixos"
# - a FAT32 EFI system partition labeled "NIXBOOT"
#
# If the VM uses different labels or UUIDs, replace this file with:
#   nixos-generate-config --show-hardware-config
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  virtualisation.hypervGuest.enable = true;

  boot.initrd.availableKernelModules = [
    "hyperv_keyboard"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [
    "hv_balloon"
    "hv_netvsc"
    "hv_storvsc"
    "hv_utils"
    "hv_vmbus"
  ];
  boot.kernelParams = [
    "elevator=noop"
  ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
