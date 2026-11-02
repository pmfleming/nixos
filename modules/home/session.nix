# Session lifecycle belongs here; daemon packages own their service definitions.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  daemons = lib.genAttrs [ "app-daemon" "bt-daemon" "clip-daemon" "nm-daemon" ] (
    name: inputs.${name}.packages.${system}.default
  );
  target = "graphical-session.target";
  # background-graphical.slice starts after the target. Explicit After avoids
  # WantedBy's reverse ordering creating a cycle during UWSM shutdown.
  packagedService =
    name: package:
    let
      source = "${package}/share/systemd/user/${name}.service";
    in
    {
      "systemd/user/${name}.service" = { inherit source; };
      "systemd/user/${target}.wants/${name}.service" = { inherit source; };
      "systemd/user/${name}.service.d/uwsm-session.conf".text = ''
        [Unit]
        After=${target}
        PartOf=${target}

        [Service]
        Slice=background-graphical.slice
      '';
    };
  graphicalService = description: execStart: {
    Unit = {
      Description = description;
      After = [ target ];
      PartOf = [ target ];
    };
    Service = {
      ExecStart = execStart;
      Restart = "on-failure";
      RestartSec = "2s";
      Slice = "background-graphical.slice";
    };
    Install.WantedBy = [ target ];
  };
in
{
  imports = [
    inputs.shelllist.homeManagerModules.default
    inputs.bar-daemon.homeManagerModules.default
  ];

  # No Ringboard alias: capture and Turso storage share one clip-daemon unit.
  home.packages = builtins.attrValues daemons;
  xdg.configFile = lib.concatMapAttrs packagedService daemons;

  programs.shelllist = {
    enable = true;
    package = inputs.shelllist.packages.${system}.default;
    systemd = {
      inherit target;
      environment = lib.genAttrs [
        "SHELLLIST_BT_SOCKET"
        "SHELLLIST_NM_SOCKET"
        "SHELLLIST_APP_SOCKET"
        "SHELLLIST_BAR_SOCKET"
        "SHELLLIST_CLIP_SOCKET"
      ] (_: "1");
    };
  };

  services.bar-daemon = {
    enable = true;
    displays.enable = true;
    media.youtubeMetadata.enable = true;
    suspend.enable = true;
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || ${pkgs.uwsm}/bin/uwsm-app -s s -- hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        # Lua requires an action table; a string would toggle an awake display off.
        after_sleep_cmd = "hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 420;
          on-timeout = "hyprctl dispatch 'hl.dsp.dpms({ action = \"off\" })'";
          on-resume = "hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";
        }
        {
          timeout = 1800;
          on-timeout = "systemctl suspend";
        }
      ];
    };
  };

  # Bound activation and shutdown without concealing crashed services.
  systemd.user.servicesStartTimeoutMs = 60000;
  systemd.user.services =
    lib.genAttrs
      (
        lib.optional config.programs.shelllist.enable "shelllist"
        ++ lib.optional config.services.bar-daemon.enable "bar-daemon"
      )
      (_: {
        Service = {
          Slice = "session-graphical.slice";
          TimeoutStopSec = "5s";
        };
      })
    // {
      hyprpaper = graphicalService "Hyprland wallpaper service" "${pkgs.hyprpaper}/bin/hyprpaper";
      hyprpolkitagent = graphicalService "Hyprland PolicyKit authentication agent" "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
    };
}
