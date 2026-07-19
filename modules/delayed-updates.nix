{
  lib,
  machine,
  pkgs,
  ...
}:

let
  mkScript = (import ../lib/scripts.nix).mkShellApplication pkgs;

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
    path = ../config/scripts/delayed-nixos-update.sh;
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

      nixos-update-catchup = mkNixosUpdateCheckService {
        description = "Catch up a missed overnight NixOS update check when on AC power";
        mode = "catch-up";
        scope = "all";
        acOnly = true;
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
      delayed-nixos-update = {
        description = "Run overnight NixOS update check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 03:00:00";
          AccuracySec = "15m";
          RandomizedDelaySec = "30m";
          Persistent = true;
        };
      };

      nixos-update-catchup = {
        description = "Retry missed overnight NixOS update checks when AC power is available";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/15";
          AccuracySec = "1m";
          RandomizedDelaySec = "2m";
        };
      };
    };
  };
}
