{
  machine,
  pkgs,
  ...
}:

let
  mkScript = (import ../lib/scripts.nix).mkScriptFrom pkgs ../config/scripts;
  updateAiTools = mkScript {
    name = "update-ai-tools";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnutar
      jq
      libnotify
      nix
      procps
      util-linux
    ];
    replacements = {
      "@USERNAME@" = machine.username;
    };
  };

  commonService = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.NIX_CONFIG = ''
      max-jobs = 1
      cores = 2
    '';
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nixos-ai-tools";
      StateDirectoryMode = "0755";
      UMask = "0022";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
    };
  };
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
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nixos-ai-tools";
        StateDirectoryMode = "0755";
        ExecStart = "${updateAiTools}/bin/update-ai-tools check-stale";
      };
    };
  };

  systemd.timers = {
    nixos-ai-tools-update = {
      description = "Check nixpkgs-unstable for AI coding-tool updates every 30 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnCalendar = "*:0/30";
        AccuracySec = "1m";
        RandomizedDelaySec = "2m";
        Persistent = true;
        Unit = "nixos-ai-tools-update.service";
      };
    };

    nixos-ai-tools-stale = {
      description = "Check whether AI coding-tool updates have gone stale";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00/3:20:00";
        AccuracySec = "5m";
        Persistent = true;
        Unit = "nixos-ai-tools-stale.service";
      };
    };
  };
}
