{ pkgs }:

let
  lockFile = "/run/lock/nixos-deployment/lock";
  scriptLib = import ./scripts.nix;
in
{
  helper = pkgs.writeText "nixos-deployment-lock.sh" (
    scriptLib.withPlaceholders {
      "@DEPLOYMENT_LOCK_FILE@" = lockFile;
    } ../config/scripts/deployment-lock.sh
  );

  # Wheel may open the stable inode read-only and flock it, but cannot replace
  # it or alter its contents. Never remove this file while jobs can be running.
  tmpfilesRules = [
    "d /run/lock/nixos-deployment 0755 root root -"
    "f ${lockFile} 0640 root wheel -"
  ];
}
