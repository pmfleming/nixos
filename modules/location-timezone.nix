{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.location-timezone;
  python = pkgs.python3.withPackages (ps: [
    ps.dbus-python
    ps.pygobject3
    ps.timezonefinder
  ]);
  source = ../config/location-timezone;
in
{
  options.services.location-timezone.enable = lib.mkEnableOption "network-aware Wi-Fi/IP timezone consensus";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.automatic-timezoned.enable;
        message = "location-timezone and automatic-timezoned must not run together";
      }
      {
        assertion = config.networking.networkmanager.enable;
        message = "location-timezone requires NetworkManager connectivity monitoring";
      }
    ];

    # Same opt-in rule as automatic-timezoned: do not reset /etc/localtime to
    # the declarative Home zone on each activation. Home/weather is independent.
    time.timeZone = null;
    services.geoclue2 = {
      enable = true;
      enableNmea = false;
      geoProviderUrl = "https://api.beacondb.net/v1/geolocate";
      appConfig.location-timezone = {
        isAllowed = true;
        isSystem = true;
        users = [ (toString config.ids.uids.automatic-timezoned) ];
      };
    };
    # Retain the retired updater's account and reserved UID/GID. Renaming an
    # existing system account during activation can collide with its old UID.
    users.users.automatic-timezoned = {
      isSystemUser = true;
      uid = config.ids.uids.automatic-timezoned;
      group = "automatic-timezoned";
    };
    users.groups.automatic-timezoned.gid = config.ids.gids.automatic-timezoned;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.timedate1.set-timezone"
            && subject.user == "automatic-timezoned") {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.location-timezone-agent = {
      description = "GeoClue agent for the timezone consensus service";
      requires = [ "geoclue.service" ];
      after = [ "geoclue.service" ];
      serviceConfig = {
        User = "automatic-timezoned";
        ExecStart = "${pkgs.geoclue2-with-demo-agent}/libexec/geoclue-2.0/demos/agent";
        Restart = "on-failure";
        PrivateTmp = true;
      };
    };
    systemd.services.location-timezone = {
      description = "Update timezone only after fresh Wi-Fi and IP location agreement";
      wantedBy = [ "multi-user.target" ];
      requires = [ "location-timezone-agent.service" ];
      conflicts = [ "automatic-timezoned.service" ];
      after = [
        "automatic-timezoned.service"
        "location-timezone-agent.service"
        "NetworkManager.service"
      ];
      environment = {
        TZDIR = "${pkgs.tzdata}/share/zoneinfo";
        PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        PYTHONDONTWRITEBYTECODE = "1";
        NUMBA_DISABLE_JIT = "1";
      };
      serviceConfig = {
        Type = "exec";
        User = "automatic-timezoned";
        ExecStart = "${python}/bin/python3 ${source}/daemon.py";
        # Explicitly resume after an externally/manual-set timezone.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 25;
        StateDirectory = "location-timezone";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "location-timezone";
        RuntimeDirectoryMode = "0755";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
