{
  config,
  inputs,
  lib,
  machine,
  pkgs,
  unstablePkgs,
  ...
}:

let
  theme = import ./theme.nix { inherit lib; };
  mkScript = (import ./lib/scripts.nix).mkScriptFrom pkgs ./config/scripts;
  locale = "en_IE.UTF-8";
  shelllistPackage = inputs.shelllist.packages.${pkgs.stdenv.hostPlatform.system}.default;
  unfreePackageNames = [
    "android-studio"
    "google-chrome"
    "spotify"
    "vscode"
  ];
  trustedGitDirectories = [
    machine.configDirectory
  ]
  ++ map (name: "${machine.homeDirectory}/Projects/${name}") machine.localProjects;
  localeCategories = [
    "LC_ADDRESS"
    "LC_IDENTIFICATION"
    "LC_MEASUREMENT"
    "LC_MONETARY"
    "LC_NAME"
    "LC_NUMERIC"
    "LC_PAPER"
    "LC_TELEPHONE"
    "LC_TIME"
  ];

  cleanTuigreet = pkgs.tuigreet.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./config/patches/tuigreet-filter-fingerprint-info.patch
    ];
  });

  rebuild = mkScript {
    name = "rebuild";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
      jq
      nix
      nixos-rebuild
    ];
    replacements = {
      "@CONFIG_DIRECTORY@" = machine.configDirectory;
      "@FLAKE_ATTR@" = machine.hostName;
      "@LOCAL_INPUTS@" = lib.escapeShellArgs machine.localProjects;
    };
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./modules/ai-tools-updates.nix
    ./modules/delayed-updates.nix
    ./modules/generation-retention.nix
  ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };
  };

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfreePackageNames;

  systemd.packages = [ shelllistPackage ];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    # Show normal boot/startup status while diagnosing login/startup issues.
    consoleLogLevel = 4;
    initrd = {
      verbose = true;
      # Load the display driver in the initrd for an earlier, smoother framebuffer handoff.
      kernelModules = [ "amdgpu" ];
    };
    kernelParams = [
      "udev.log_level=info"
      "rd.udev.log_level=info"
      "systemd.show_status=true"
      "rd.systemd.show_status=true"
    ];
    # Make the Qualcomm Wi-Fi device appear reliably after generation switches/reboots.
    kernelModules = [ "ath11k_pci" ];
  };

  networking = {
    inherit (machine) hostName;
    networkmanager = {
      enable = true;
      # Keep NetworkManager and systemd-resolved on one DNS backend. This also
      # provides the resolve1 D-Bus service NetworkManager flushes on reconnect.
      dns = "systemd-resolved";
      settings.connectivity = {
        enabled = true;
        uri = "http://nmcheck.gnome.org/check_network_status.txt";
        response = "NetworkManager is online";
        interval = 300;
      };
    };
    firewall.enable = true;
  };
  # NetworkManager-wait-online can take ~10s on Wi-Fi while autoconnect/DHCP
  # settle. This does not block graphical login; it only gates units that
  # explicitly wait for network-online.target, such as the update timer service.
  # Keep it enabled so those jobs start with a real network when available.

  time.timeZone = lib.mkDefault "Europe/Amsterdam";
  i18n = {
    defaultLocale = locale;
    extraLocaleSettings = lib.genAttrs localeCategories (_: locale);
  };
  console.keyMap = "us";

  services = {
    automatic-timezoned.enable = true;
    # Shelllist runs as a user service, but its privileged battery helper must
    # be registered with the system D-Bus instance.
    dbus.packages = [ shelllistPackage ];
    # Allow the user-level app daemon to sample CPU package energy through RAPL.
    # Desktop users already receive hardware access through the video group.
    udev = {
      extraRules = ''
        ACTION=="add|change", SUBSYSTEM=="powercap", TEST=="energy_uj", ATTR{enabled}="1", RUN+="${pkgs.coreutils}/bin/chgrp video /sys%p/energy_uj", RUN+="${pkgs.coreutils}/bin/chmod 0440 /sys%p/energy_uj"
      '';
      # FIDO2/WebAuthn security key support for browser passkeys.
      packages = [ pkgs.libfido2 ];
    };
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
    # Automatic timezone detection only needs GeoClue's Wi-Fi provider. Disable
    # local-network NMEA discovery instead of warning about a missing Avahi daemon.
    geoclue2.enableNmea = false;
    resolved.enable = true;
    # WirePlumber and desktop battery consumers expect UPower on a laptop.
    upower.enable = true;
    greetd = {
      enable = true;
      useTextGreeter = true;
      settings.default_session = {
        command = "${cleanTuigreet}/bin/tuigreet --time --remember --prompt-padding 0 --cmd '${config.programs.uwsm.package}/bin/uwsm start -e -D Hyprland hyprland.desktop'";
        user = "greeter";
      };
    };
    gnome.gnome-keyring.enable = true;
    # Fingerprint reader support for login and lock-screen biometric auth.
    # The patched tuigreet above filters PAM's instructional fingerprint text.
    fprintd.enable = true;
    printing.enable = true;
    blueman.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    power-profiles-daemon.enable = true;
    logind.settings.Login = {
      HandlePowerKey = "suspend";
      HandleLidSwitch = "suspend";
      HandleLidSwitchDocked = "ignore";
    };
  };

  programs = {
    hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };
    dconf.enable = true;
    command-not-found.enable = false;
    nix-index.enable = true;
    # Root-run update evaluation intentionally reads these exact deployment and
    # machine-local development repositories. Do not broaden this to "*".
    git = {
      enable = true;
      config.safe.directory = trustedGitDirectories;
    };
  };

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-hyprland
      xdg-desktop-portal-gtk
    ];
    config.common.default = [
      "hyprland"
      "gtk"
    ];
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    graphics = {
      enable = true;
      enable32Bit = true;
    };
    enableRedistributableFirmware = true;
  };

  zramSwap.enable = true;

  # Enable fingerprint login for greetd/tuigreet. The patched tuigreet package
  # filters fprintd's instructional PAM info messages from the visible prompt.
  security = {
    polkit.enable = true;
    rtkit.enable = true;
    pam.services = {
      greetd = {
        fprintAuth = true;
        enableGnomeKeyring = true;
      };
      # Hyprlock uses its native fingerprint support, so keep PAM fingerprint off
      # there to avoid duplicate/serial fingerprint handling. Password stays fallback.
      hyprlock.fprintAuth = false;
    };
  };

  fonts = {
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      font-awesome
      noto-fonts
      noto-fonts-color-emoji
    ];
    fontconfig.defaultFonts = {
      monospace = [ theme.fonts.code ];
      sansSerif = [ theme.fonts.ui ];
      serif = [ theme.fonts.serif ];
    };
  };

  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets."${machine.username}-password".neededForUsers = true;
  };

  # Keep login credentials reproducible. Restore the Age identity before the
  # first rebuild of a fresh installation so sops-nix can create this user.
  users = {
    mutableUsers = false;
    groups.plugdev = { };
    users.${machine.username} = {
      isNormalUser = true;
      description = "Paul Fleming";
      hashedPasswordFile = config.sops.secrets."${machine.username}-password".path;
      extraGroups = [
        "audio"
        "input"
        "kvm"
        "networkmanager"
        "plugdev"
        "video"
        "wheel"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    # Polkit only discovers action definitions linked into the system profile.
    # The helper's D-Bus/systemd registration alone is not sufficient.
    shelllistPackage

    (mkScript {
      name = "google-chrome-fullscreen";
      runtimeInputs = [ google-chrome ];
    })

    rebuild

    (mkScript {
      name = "rollback";
      runtimeInputs = [ nixos-rebuild ];
    })

    adwaita-icon-theme
    adwaita-qt
    android-studio
    android-tools
    bibata-cursors
    brightnessctl
    # Bootstrap fallbacks remain in the system generation. The independent,
    # independently GC-rooted profile shadows these paths for normal user
    # sessions without switching NixOS or Home Manager.
    unstablePkgs.claude-code
    curl
    fd
    libfido2
    gh
    git
    google-chrome
    drm_info
    edid-decode
    electrum
    grim
    jq
    kdePackages.okular
    libdrm
    libnotify
    neovim
    nodejs
    nwg-displays
    pavucontrol
    unstablePkgs.pi-coding-agent
    unstablePkgs.t3code
    playerctl
    ripgrep
    slurp
    spotify
    swaynotificationcenter
    satty
    tree
    unzip
    vscode
    wget
    wl-clipboard
    xdg-utils
  ];

  system.stateVersion = "26.05";
}
