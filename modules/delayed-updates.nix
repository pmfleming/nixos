{ updateWorker, ... }:

let
  systemdLib = import ../lib/systemd.nix;
  mkService =
    description: command:
    systemdLib.nixBuildService {
      ExecStart = "${updateWorker}/bin/update-worker ${command}";
      StateDirectory = "nixos-delayed-updates-v2";
      TimeoutStartSec = "6h";
    }
    // {
      inherit description;
    };
  onACPower = service: service // { unitConfig.ConditionACPower = true; };
in
{
  # Rebuild invokes approval directly to pass its private source manifest. The
  # updater still owns serialization of approval metadata through its state lock.
  system.build.delayedNixosUpdate = updateWorker;
  environment.systemPackages = [ updateWorker ];

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

      # Metadata only: no builds/deployment, and no network work in status/Refresh.
      nixos-update-application-releases = {
        description = "Cache known upstream application release versions";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updateWorker}/bin/update-worker check-applications";
          StateDirectory = "nixos-delayed-updates-v2";
          UMask = "0022";
          TimeoutStartSec = "6min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
    };

    timers = {
      nixos-update-application-releases = systemdLib.timer "Refresh cached application release metadata" {
        OnBootSec = "10min";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "5min";
        Persistent = false;
      };

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
