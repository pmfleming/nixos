{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # A separate pin updates only the experimental display/kernel closures, not
  # the base OS, Home Manager or the local daemon build graph.
  displayPkgs = import inputs.nixpkgs-display {
    system = pkgs.stdenv.hostPlatform.system;
  };
  kernel = {
    boot.kernelPackages = displayPkgs.linuxPackages_6_18;
  };
  display = {
    programs.hyprland = {
      package = displayPkgs.hyprland;
      portalPackage = displayPkgs.xdg-desktop-portal-hyprland;
    };
    # Keep the GL drivers and both architectures from the same package set as
    # the new compositor. Never replace just libaquamarine across an ABI bump.
    hardware.graphics = {
      package = displayPkgs.mesa;
      package32 = displayPkgs.pkgsi686Linux.mesa;
    };
  };
in
{
  # The default entry remains the DPMS-only baseline. Specialisations inherit
  # those hooks and diagnostics, but do not become active merely by building.
  specialisation = {
    hdmi-kernel.configuration = kernel;
    hdmi-display.configuration = display;
    hdmi-combined.configuration = lib.mkMerge [
      kernel
      display
    ];
  };
}
