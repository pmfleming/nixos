{ updateAiTools, ... }:

let
  systemdLib = import ../lib/systemd.nix;
  commonService = systemdLib.nixBuildService "nixos-ai-tools";
in
{
  systemd.services = {
    nixos-ai-tools-update = commonService // {
      description = "Build and atomically activate current AI coding tools";
      serviceConfig = commonService.serviceConfig // {
        ExecStart = "${updateAiTools}/bin/update-ai-tools update";
        TimeoutStartSec = "2h";
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
        StateDirectory = "nixos-ai-tools";
        StateDirectoryMode = "0755";
        ExecStart = "${updateAiTools}/bin/update-ai-tools check-stale";
      };
    };
  };

  systemd.timers = {
    nixos-ai-tools-update =
      systemdLib.timer "Check nixpkgs-unstable for AI coding-tool updates every 30 minutes"
        {
          OnBootSec = "2m";
          OnCalendar = "*:0/30";
          AccuracySec = "1m";
          RandomizedDelaySec = "2m";
          Unit = "nixos-ai-tools-update.service";
        };

    nixos-ai-tools-stale = systemdLib.timer "Check whether AI coding-tool updates have gone stale" {
      OnCalendar = "*-*-* 00/3:20:00";
      AccuracySec = "5m";
      Unit = "nixos-ai-tools-stale.service";
    };
  };
}
