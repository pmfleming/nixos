{ inputs, pkgs, ... }:
let
  # Promote the proven hdmi-combined stack without updating the base OS,
  # Home Manager or the local daemon build graph.
  displayPkgs = import inputs.nixpkgs-display {
    system = pkgs.stdenv.hostPlatform.system;
  };
in
{
  boot.kernelPackages = displayPkgs.linuxPackages_6_18;

  programs.hyprland = {
    package = displayPkgs.hyprland;
    portalPackage = displayPkgs.xdg-desktop-portal-hyprland;
  };
  # Keep the compositor, portal and both GL driver architectures together.
  # Never replace just libaquamarine across an ABI bump.
  hardware.graphics = {
    package = displayPkgs.mesa;
    package32 = displayPkgs.pkgsi686Linux.mesa;
  };
}
