{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkScript = (import ../lib/scripts.nix).mkShellApplication pkgs;
  pruneNixosGenerations = mkScript {
    name = "prune-nixos-generations";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.gawk
    ];
    path = ../config/scripts/prune-nixos-generations.sh;
  };
  userProfiles = [
    "/home/laufan/.local/state/nix/profiles/home-manager"
    "/home/laufan/.local/state/nix/profiles/profile"
  ];
in
{
  # This bounded policy handles system-profile garbage collection.
  nix.gc.automatic = false;

  systemd.services.prune-nixos-generations = {
    description = "Prune system and Home Manager generations with bounded retention";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pruneNixosGenerations}/bin/prune-nixos-generations
      for profile in ${lib.escapeShellArgs userProfiles}; do
        if [[ -e "$profile" ]]; then
          ${pkgs.util-linux}/bin/runuser --user laufan -- \
            ${pruneNixosGenerations}/bin/prune-nixos-generations \
            --profile "$profile" \
            --no-refresh-boot
        fi
      done
    '';
  };

  systemd.timers.prune-nixos-generations = {
    description = "Run system and Home Manager generation pruning once per day";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemd.services.nix-store-gc = {
    description = "Garbage collect unreferenced Nix store paths";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.nix.package}/bin/nix-store --gc";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
    };
  };

  systemd.timers.nix-store-gc = {
    description = "Garbage collect the Nix store weekly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
