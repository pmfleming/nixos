{ ... }:

{
  imports = [
    ./modules/nixos/core.nix
    ./modules/nixos/boot.nix
    ./modules/nixos/locale.nix
    ./modules/nixos/networking.nix
    ./modules/nixos/desktop.nix
    ./modules/nixos/services.nix
    ./modules/nixos/hardware.nix
    ./modules/nixos/fonts.nix
    ./modules/nixos/users.nix
    ./modules/nixos/packages.nix
  ];
}
