{
  lib,
  machine,
  pkgs,
  ...
}:

let
  systemdLib = import ../lib/systemd.nix;
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

  commonService = systemdLib.nixBuildService "nixos-delayed-updates-v2";
  mkService =
    description: command:
    commonService
    // {
      inherit description;
      serviceConfig = commonService.serviceConfig // {
        ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${command}";
        TimeoutStartSec = "6h";
      };
    };
  onACPower = service: service // { unitConfig.ConditionACPower = true; };
in
{
  systemd = {
    services = {
      # One process discovers, matures, builds, and stages the delayed lane.
      # There is no OnSuccess apply chain: a skipped check is not an update.
      nixos-update-delayed = onACPower (
        mkService "Quarantine, build, and stage remote NixOS input updates for next boot" "run-delayed"
      );

      nixos-update-delayed-catchup = onACPower (
        mkService "Retry an overdue delayed NixOS update check on AC power" "catch-up-delayed"
      );

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

    timers = {
      nixos-update-delayed = systemdLib.timer "Check quarantined NixOS flake inputs daily" {
        OnCalendar = "*-*-* 03:00:00";
        AccuracySec = "30m";
        RandomizedDelaySec = "30m";
        Unit = "nixos-update-delayed.service";
      };

      nixos-update-delayed-catchup =
        systemdLib.timer "Retry overdue delayed NixOS update checks when AC power is available"
          {
            OnCalendar = "*:0/30";
            AccuracySec = "1m";
            Persistent = false;
            RandomizedDelaySec = "5m";
            Unit = "nixos-update-delayed-catchup.service";
          };
    };
  };
}
