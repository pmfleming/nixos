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
  theme = import ./theme.nix;
  deploymentLock = import ./lib/deployment-lock.nix { inherit pkgs; };
  mkScript = (import ./lib/scripts.nix).mkScriptFrom pkgs ./config/scripts;
  locale = "en_IE.UTF-8";
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

  rebuild = inputs.update-daemon.lib.mkRebuild {
    inherit pkgs;
    worker = config.system.build.delayedNixosUpdate;
    deploymentLockHelper = deploymentLock.helper;
    configDirectory = machine.configDirectory;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    inputs.update-daemon.nixosModules.tools
    ./modules/application-inventory.nix
    inputs.update-daemon.nixosModules.system
    ./modules/dbus-discovery.nix
    ./modules/generation-retention.nix
    ./modules/printers.nix
    inputs.update-daemon.nixosModules.buildCache
    inputs.bar-daemon.nixosModules.default
    inputs.bar-daemon.nixosModules.location-timezone
    inputs.app-daemon.nixosModules.default
    inputs.bt-daemon.nixosModules.audio-stack
    inputs.bt-daemon.nixosModules.rssi-helper
    inputs.nm-daemon.nixosModules.discovery
    # Explicitly deploy the validated stable NM package alongside its adapter.
    inputs.nm-daemon.nixosModules.networkManager
  ];

  services.build-cache-trim = {
    enable = true;
    user = machine.username;
    maxGiB = 4;
    retentionDays = 14;
    sharedCaches = {
      enable = true;
      maxGiB = 1;
    };
    workspaceRoots = [
      "${machine.homeDirectory}/Projects"
      "${machine.homeDirectory}/Projects-p2"
    ];
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      # Match rebuild's defaults, including unattended/local development builds.
      max-jobs = 2;
      cores = 8;
    };
  };

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfreePackageNames;

  # Expose the new wrapper for bootstrapping before the installed rebuild updates.
  system.build.rebuild = rebuild;

  systemd.tmpfiles.rules = deploymentLock.tmpfilesRules;

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    # Show normal boot/startup status while diagnosing login/startup issues.
    consoleLogLevel = 4;
    initrd = {
      # Resume from the swapfile using systemd's HibernateLocation EFI variable.
      # No fixed resume device or swapfile offset is needed on this UEFI system.
      systemd.enable = true;
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
    automatic-timezoned.enable = false;
    location-timezone.enable = true;
    # Allow diagnostic location clients without changing timezone management.
    geoclue2.enable = true;
    bar-daemon.batteryHelper.enable = true;
    # Deploy bt-daemon's matched BlueZ/PipeWire/WirePlumber runtime packages.
    bt-daemon.audioStack.enable = true;
    # Connected-device signal strength for Shelllist; CAP_NET_ADMIN stays in
    # this confined system helper, never the bt-daemon user service.
    bt-rssi-helper.enable = true;
    app-daemon.resources.enableRaplAccess = true;
    # Preserve this host's existing resolver mode and inherited profile policy.
    # Integration belongs to nm-daemon, not the presentation shell.
    nm-daemon.discovery = {
      enable = true;
      multicastDNS = "true";
      defaultMdns = -1;
    };
    # FIDO2/WebAuthn security key support for browser passkeys.
    udev.packages = [ pkgs.libfido2 ];
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
    blueman.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    power-profiles-daemon.enable = true;
    # Check and apply Lenovo firmware updates through fwupd/LVFS on demand.
    fwupd.enable = true;
    logind.settings.Login = {
      # Avoid re-suspending an already-awake laptop during black-screen recovery.
      # Firmware still handles waking the laptop with the power button.
      HandlePowerKey = "ignore";
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
    # programs.hyprland supplies the matching portal from nixpkgs-display.
    # Do not also install the base package here.
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
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

  # Persistent hibernation storage; prefer zram (priority 5) for normal swapping.
  # Root is unencrypted, so this file also stores memory contents unencrypted.
  swapDevices = [
    {
      device = "/swapfile";
      size = 64 * 1024; # MiB: 64 GiB for approximately 59 GiB of usable RAM.
      priority = 0;
    }
  ];

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
      # Do not grant permanent raw input access: it lets any user process read
      # keyboard events outside Wayland's focus and lock-screen isolation.
      extraGroups = [
        "audio"
        "kvm"
        "networkmanager"
        "plugdev"
        "video"
        "wheel"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    (mkScript {
      name = "google-chrome-fullscreen";
      runtimeInputs = [ google-chrome ];
    })

    rebuild
    inputs.daemon-framework.packages.${pkgs.stdenv.hostPlatform.system}.localBuild

    (mkScript {
      name = "rollback";
      runtimeInputs = [
        nixos-rebuild
        util-linux
      ];
      replacements."@DEPLOYMENT_LOCK_HELPER@" = "${deploymentLock.helper}";
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
    pavucontrol
    unstablePkgs.pi-coding-agent
    unstablePkgs.t3code
    playerctl
    ripgrep
    slurp
    spotify
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
