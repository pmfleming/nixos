{
  pkgs,
  nixpkgsDisplay,
  toolsPkgs ? pkgs,
}:

# Graphics drivers are dlopened into applications from the base OS. A binary
# from nixpkgs-display can require a newer glibc than those already-running
# processes provide. Keep the display pin's Mesa recipe/version, but build its
# complete dependency graph with the base package set (also for 32-bit clients).
pkgs.callPackage (nixpkgsDisplay + "/pkgs/development/libraries/mesa") {
  # This package installs only SPIR-V data (both 32/64-bit forms). Share the
  # native compiler's result instead of building a second 32-bit LLVM/Clang.
  mesa-libclc = toolsPkgs.callPackage (
    nixpkgsDisplay + "/pkgs/by-name/me/mesa-libclc/package.nix"
  ) { };
}
