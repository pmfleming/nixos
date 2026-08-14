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
    replacements."@FLAKE_ATTR@" = machine.hostName;
  };

  commonUnit = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.NIX_CONFIG = ''
      max-jobs = 1
      cores = 2
    '';
  };

  prepareService =
    {
      description,
      command,
      autoApply ? null,
      acOnly ? false,
    }:
    commonUnit
    // {
      inherit description;
      unitConfig =
        lib.optionalAttrs acOnly {
          ConditionACPower = true;
        }
        // lib.optionalAttrs (autoApply != null) {
          OnSuccess = autoApply;
        };
      serviceConfig = {
        Type = "oneshot";
        User = machine.username;
        StateDirectory = "nixos-delayed-updates";
        StateDirectoryMode = "0755";
        UMask = "0022";
        ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${command}";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
    };

  applyService =
    description: command:
    commonUnit
    // {
      inherit description;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${command}";
      };
    };

  mkTimer = description: unit: timerOptions: {
    inherit description;
    wantedBy = [ "timers.target" ];
    timerConfig = timerOptions // {
      Unit = unit;
    };
  };
in
{
  systemd = {
    services = {
      nixos-update-fast = prepareService {
        description = "Check and build immediate updates for Codex, Pi, and Claude";
        command = "check-fast";
        autoApply = "nixos-update-apply-fast.service";
        acOnly = true;
      };

      nixos-update-delayed = prepareService {
        description = "Discover, quarantine, and build other NixOS flake updates";
        command = "check-delayed";
        autoApply = "nixos-update-apply-delayed.service";
        acOnly = true;
      };

      delayed-nixos-update = prepareService {
        description = "Catch up overdue immediate and delayed NixOS update checks";
        command = "catch-up";
        autoApply = "nixos-update-apply-ready.service";
        acOnly = true;
      };

      # Manual staging commands intentionally omit OnSuccess.
      nixos-update-check-apps = prepareService {
        description = "Stage nixpkgs-unstable updates for Codex, Pi, and Claude";
        command = "check-fast";
      };

      nixos-update-check-all = prepareService {
        description = "Stage matured updates for all inputs except nixpkgs-unstable";
        command = "check-delayed";
      };

      nixos-update-apply-fast = applyService "Apply a checked immediate AI-tools update" "apply-fast";
      nixos-update-apply-delayed = applyService "Apply a checked quarantined NixOS update" "apply-delayed";
      nixos-update-apply-ready = applyService "Apply any checked NixOS update candidates" "apply-ready";
      nixos-update-approve = applyService "Manually apply any checked NixOS update candidates" "apply-ready";
    };

    timers = {
      nixos-update-fast =
        mkTimer "Check fast-moving AI coding tools every six hours" "nixos-update-fast.service"
          {
            OnCalendar = "*-*-* 00,06,12,18:00:00";
            AccuracySec = "15m";
            RandomizedDelaySec = "20m";
            Persistent = true;
          };

      nixos-update-delayed =
        mkTimer "Check quarantined NixOS flake inputs daily" "nixos-update-delayed.service"
          {
            OnCalendar = "*-*-* 03:00:00";
            AccuracySec = "30m";
            RandomizedDelaySec = "30m";
            Persistent = true;
          };

      nixos-update-catchup =
        mkTimer "Retry missed update checks when AC power becomes available" "delayed-nixos-update.service"
          {
            OnCalendar = "*:0/15";
            AccuracySec = "1m";
            RandomizedDelaySec = "2m";
          };
    };
  };
}
