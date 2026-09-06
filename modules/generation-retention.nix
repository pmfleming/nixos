{
  config,
  lib,
  machine,
  pkgs,
  ...
}:

let
  systemdLib = import ../lib/systemd.nix;
  deploymentLock = import ../lib/deployment-lock.nix { inherit pkgs; };
  mkScript = (import ../lib/scripts.nix).mkScriptFrom pkgs ../config/scripts;
  pruneNixosGenerations = mkScript {
    name = "prune-nixos-generations";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.gawk
      pkgs.util-linux
    ];
    replacements."@DEPLOYMENT_LOCK_HELPER@" = "${deploymentLock.helper}";
  };
  userProfiles = map (name: "${machine.homeDirectory}/.local/state/nix/profiles/${name}") [
    "home-manager"
    "profile"
  ];
  mkTimer =
    description: OnCalendar:
    systemdLib.timer description {
      inherit OnCalendar;
      RandomizedDelaySec = "1h";
    };
in
{
  # This bounded policy handles system-profile garbage collection.
  nix.gc.automatic = false;

  systemd = {
    services = {
      prune-nixos-generations = {
        description = "Prune system and Home Manager generations with bounded retention";
        serviceConfig = {
          Type = "oneshot";
          # Lock contention is a harmless skip; try again at the next timer run.
          SuccessExitStatus = [ 75 ];
        };
        script = ''
          ${pruneNixosGenerations}/bin/prune-nixos-generations
          for profile in ${lib.escapeShellArgs userProfiles}; do
            if [[ -e "$profile" ]]; then
              ${pkgs.util-linux}/bin/runuser --user ${machine.username} -- \
                ${pruneNixosGenerations}/bin/prune-nixos-generations \
                --profile "$profile" \
                --no-refresh-boot
            fi
          done
        '';
      };

      nix-store-gc = {
        description = "Garbage collect unreferenced Nix store paths";
        serviceConfig = systemdLib.lowPriority // {
          Type = "oneshot";
          ExecStart = "${config.nix.package}/bin/nix-store --gc";
        };
      };
    };

    timers = {
      prune-nixos-generations = mkTimer "Run system and Home Manager generation pruning once per day" "daily";
      nix-store-gc = mkTimer "Garbage collect the Nix store weekly" "Sun 04:00";
    };
  };
}
