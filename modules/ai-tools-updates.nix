{ vendorAiTools, ... }:

let
  systemdLib = import ../lib/systemd.nix;
  commonService = systemdLib.nixBuildService "nixos-ai-tools";
in
{
  environment.systemPackages = [ vendorAiTools.updater ];

  systemd.services = {
    nixos-ai-tools-update = commonService // {
      description = "Check official AI releases and independently activate checked tools";
      serviceConfig = commonService.serviceConfig // {
        ExecStart = "${vendorAiTools.updater}/bin/ai-tools update";
        StateDirectory = [
          "nixos-ai-tools"
          "nixos-delayed-updates-v2"
        ];
        TimeoutStartSec = "50min";
        TimeoutStopSec = "3min";
        KillMode = "mixed";
      };
    };

    nixos-ai-tools-stale = {
      description = "Report a stale AI coding-tools profile";
      # Persistent timers can both catch up immediately after boot or resume.
      # Retry and wait for the updater before deciding that its state is stale.
      wants = [ "nixos-ai-tools-update.service" ];
      after = [ "nixos-ai-tools-update.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = [
          "nixos-ai-tools"
          "nixos-delayed-updates-v2"
        ];
        StateDirectoryMode = "0755";
        UMask = "0022";
        ExecStart = "${vendorAiTools.updater}/bin/ai-tools stale";
        TimeoutStartSec = "5min";
        TimeoutStopSec = "3min";
        KillMode = "mixed";
      };
    };
  };

  systemd.timers = {
    nixos-ai-tools-update = systemdLib.timer "Check official stable AI-tool releases every 15 minutes" {
      OnBootSec = "2m";
      OnCalendar = "*:0/15";
      AccuracySec = "1m";
      RandomizedDelaySec = "2m";
      Unit = "nixos-ai-tools-update.service";
    };

    nixos-ai-tools-stale = systemdLib.timer "Check whether AI coding-tool updates have gone stale" {
      OnCalendar = "hourly";
      AccuracySec = "1m";
      Unit = "nixos-ai-tools-stale.service";
    };
  };
}
