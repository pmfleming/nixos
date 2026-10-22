{ config, lib, updateWorker ? null, ... }:

let
  # Evaluation-time package metadata, carried by each immutable generation. Reading
  # Updates must never evaluate a flake, realise a derivation or contact upstream.
  github = repo: tag_prefix: { provider = "github"; inherit repo tag_prefix; };
  # Explicit upstream/channel identities, not guesses from pname, homepage or a
  # pending Nix target. Unsupported packages remain unknown. A package may carry
  # a reviewed passthru.shelllistReleaseSource override using this same schema.
  sources = {
    google-chrome = { provider = "chrome-stable"; };
    vscode = { provider = "vscode-stable"; };
    fd = github "sharkdp/fd" "v";
    gh = github "cli/cli" "v";
    jq = github "jqlang/jq" "jq-";
    neovim = github "neovim/neovim" "v";
    ripgrep = github "BurntSushi/ripgrep" "";
    satty = github "Satty-org/Satty" "v";
    playerctl = github "altdesktop/playerctl" "v";
    wl-clipboard = github "bugaevc/wl-clipboard" "v";
    libfido2 = github "Yubico/libfido2" "";
    pi-coding-agent = github "earendil-works/pi" "v";
    t3code = github "pingdotgg/t3code" "v";
  };
  packages =
    scope: values:
    map (package:
      let
        name = package.pname or (lib.getName package);
        source = package.passthru.shelllistReleaseSource or (sources.${name} or null);
      in {
        inherit scope name;
        version = package.version or null;
      } // lib.optionalAttrs (source != null) { release_source = source; }
    ) values;
  inventory = lib.unique (
    packages "system" config.environment.systemPackages
    ++ lib.concatLists (
      lib.mapAttrsToList (user: home: packages "user:${user}" home.home.packages) (
        config.home-manager.users or { }
      )
    )
  );
in
{
  environment.etc."shelllist/application-inventory.json".text = builtins.toJSON {
    schema_version = 1;
    packages = inventory;
  };
  # Finite metadata checks only; no build/deployment command, and no network work
  # in status --json or panel Refresh. Activation enables this schedule normally.
  systemd.services.nixos-update-application-releases = lib.mkIf (updateWorker != null) {
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
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };
  systemd.timers.nixos-update-application-releases = lib.mkIf (updateWorker != null) {
    description = "Refresh cached application release metadata";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "5min";
      Persistent = false;
    };
  };
}
