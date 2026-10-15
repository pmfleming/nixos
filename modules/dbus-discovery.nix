{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dbus;
  upstream = pkgs.makeDBusConf.override {
    inherit (cfg) apparmor;
    dbus = cfg.dbusPackage;
    suidHelper = "${config.security.wrapperDir}/dbus-daemon-launch-helper";
    serviceDirectories = lib.unique cfg.packages;
  };
  canonical =
    pkgs.runCommand "canonical-dbus-configuration" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        python3 ${../config/scripts/canonical-dbus.py} ${upstream} $out ${config.system.path}
      '';
in
{
  config = lib.mkIf cfg.enable {
    # Correct the upstream activation filename; standard XDG discovery also sees
    # this file, so fixing only the generated explicit directory is insufficient.
    nixpkgs.overlays = [
      (_final: prev: {
        obex_data_server = prev.obex_data_server.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            mv "$out/share/dbus-1/services/obex-data-server.service" \
              "$out/share/dbus-1/services/org.openobex.service"
          '';
        });
      })
    ];
    environment.etc."dbus-1".source = lib.mkForce canonical;
    # Keep the upstream reload-only behaviour. Never restart the live bus.
    systemd.services.${
      if cfg.implementation == "broker" then "dbus-broker" else "dbus"
    }.restartTriggers =
      [ canonical ];
    systemd.user.services.${
      if cfg.implementation == "broker" then "dbus-broker" else "dbus"
    }.restartTriggers =
      [ canonical ];
  };
}
