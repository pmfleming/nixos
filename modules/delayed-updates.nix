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
      nix
      nixos-rebuild
      procps
      util-linux
    ];
    replacements."@FLAKE_ATTR@" = machine.hostName;
  };

  mkNixosUpdateCheckService =
    {
      description,
      scope,
      mode ? "check",
      acOnly ? false,
    }:
    {
      inherit description;
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.NIX_CONFIG = ''
        max-jobs = 1
        cores = 2
      '';
      unitConfig = lib.optionalAttrs acOnly {
        ConditionACPower = true;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${mode}${
          lib.optionalString (mode == "check") " ${scope}"
        }";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
    };

  mkTimer = description: timerConfig: {
    inherit description timerConfig;
    wantedBy = [ "timers.target" ];
  };
  catchupDescription = "Retry missed overnight NixOS update checks when AC power is available";
in
{
  systemd = {
    services = {
      delayed-nixos-update = mkNixosUpdateCheckService {
        description = "Check and build NixOS flake updates for manual approval";
        mode = "catch-up";
        scope = "all";
        acOnly = true;
      };

      nixos-update-check-all = mkNixosUpdateCheckService {
        description = "Check and build updates for all NixOS flake inputs";
        scope = "all";
      };

      nixos-update-check-apps = mkNixosUpdateCheckService {
        description = "Check and build nixpkgs-unstable updates for Codex, Pi, and Claude";
        scope = "apps";
      };

      nixos-update-approve = {
        description = "Apply a checked NixOS flake update after manual approval";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update approve";
        };
      };
    };

    timers = {
      delayed-nixos-update = mkTimer "Run overnight NixOS update check" {
        OnCalendar = "*-*-* 03:00:00";
        AccuracySec = "15m";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };

      nixos-update-catchup = mkTimer catchupDescription {
        Unit = "delayed-nixos-update.service";
        OnCalendar = "*:0/15";
        AccuracySec = "1m";
        RandomizedDelaySec = "2m";
      };
    };
  };
}
