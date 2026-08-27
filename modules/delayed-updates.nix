{
  lib,
  machine,
  pkgs,
  ...
}:

let
  mkScript = (import ../lib/scripts.nix).mkScriptFrom pkgs ../config/scripts;

  delayedNixosUpdate = mkScript {
    name = "delayed-nixos-update";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      git
      gnutar
      jq
      nix
      procps
      util-linux
    ];
    replacements = {
      "@FLAKE_ATTR@" = machine.hostName;
      "@MANUAL_INPUTS@" = lib.concatStringsSep " " machine.localProjects;
    };
  };

  mkService = description: command: {
    inherit description;
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.NIX_CONFIG = ''
      max-jobs = 1
      cores = 2
    '';
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nixos-delayed-updates-v2";
      StateDirectoryMode = "0755";
      UMask = "0022";
      ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${command}";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
      TimeoutStartSec = "6h";
    };
  };
in
{
  systemd = {
    services = {
      # One process discovers, matures, builds, and stages the delayed lane.
      # There is no OnSuccess apply chain: a skipped check is not an update.
      nixos-update-delayed =
        (mkService "Quarantine, build, and stage remote NixOS input updates for next boot" "run-delayed")
        // {
          unitConfig.ConditionACPower = true;
        };

      nixos-update-check-all = mkService "Check quarantined remote NixOS flake updates" "check-delayed manual";

      nixos-update-apply-delayed = mkService "Stage a checked NixOS update for next boot" "apply-delayed";

      nixos-update-approve-baseline = {
        description = "Record a successful manual rebuild as the unattended-update baseline";
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "nixos-delayed-updates-v2";
          StateDirectoryMode = "0755";
          UMask = "0022";
          ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update approve-current";
        };
      };
    };

    timers.nixos-update-delayed = {
      description = "Check quarantined NixOS flake inputs daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03:00:00";
        AccuracySec = "30m";
        RandomizedDelaySec = "30m";
        Persistent = true;
        Unit = "nixos-update-delayed.service";
      };
    };
  };
}
