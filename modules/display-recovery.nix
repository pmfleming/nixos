{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # Promote the proven hdmi-combined stack without updating the base OS,
  # Home Manager or the local daemon build graph.
  displayPkgs = import inputs.nixpkgs-display {
    system = pkgs.stdenv.hostPlatform.system;
  };
  mesaFor =
    packageSet:
    import ../lib/display-mesa.nix {
      pkgs = packageSet;
      toolsPkgs = pkgs;
      nixpkgsDisplay = inputs.nixpkgs-display;
    };
in
{
  # A newer compositor can load older-libc drivers, but an older-libc desktop
  # process cannot load newer-libc drivers. Reject that combination at evaluation.
  assertions = [
    {
      assertion = lib.versionAtLeast pkgs.stdenv.cc.libc.version config.hardware.graphics.package.stdenv.cc.libc.version;
      message = "Mesa must be built against the base OS glibc; nixpkgs-display binary drivers can break desktop OpenGL.";
    }
    {
      assertion = lib.versionAtLeast pkgs.pkgsi686Linux.stdenv.cc.libc.version config.hardware.graphics.package32.stdenv.cc.libc.version;
      message = "32-bit Mesa must be built against the base OS glibc.";
    }
  ];
  boot.kernelPackages = displayPkgs.linuxPackages_6_18;

  programs.hyprland = {
    package = displayPkgs.hyprland;
    portalPackage = displayPkgs.xdg-desktop-portal-hyprland;
  };
  # Keep the display pin's Mesa version on both architectures, rebuilt with the
  # base OS libraries for application loader compatibility. Aquamarine still
  # comes with the compositor; never replace that library across an ABI bump.
  hardware.graphics = {
    package = mesaFor pkgs;
    package32 = mesaFor pkgs.pkgsi686Linux;
  };
}
