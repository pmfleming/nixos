{
  config,
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
      gawk
      git
      gnused
      jq
      nix
      nixos-rebuild
      util-linux
    ];
    replacements."@FLAKE_ATTR@" = machine.hostName;
  };

  update = mkScript {
    name = "update";
    runtimeInputs = [
      pkgs.nix
      rebuild
    ];
    replacements."@FLAKE_ATTR@" = machine.hostName;
  };
in
{
  imports = [
    ./hardware-configuration.nix
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

  nixpkgs.config.allowUnfree = true;

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
    greetd = {
      enable = true;
      useTextGreeter = true;
      settings.default_session = {
        command = "${cleanTuigreet}/bin/tuigreet --time --remember --prompt-padding 0 --cmd ${config.programs.hyprland.package}/bin/start-hyprland";
        user = "greeter";
      };
    };
    gnome.gnome-keyring.enable = true;
    # Fingerprint reader support for login and lock-screen biometric auth.
    # The patched tuigreet above filters PAM's instructional fingerprint text.
    fprintd.enable = true;
    printing.enable = true;
    flatpak.enable = true;
    # FIDO2/WebAuthn security key support for browser passkeys.
    udev.packages = [ pkgs.libfido2 ];
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
      xwayland.enable = true;
    };
    dconf.enable = true;
    command-not-found.enable = false;
    nix-index.enable = true;
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
    secrets."laufan-password".neededForUsers = true;
  };

  # Keep login credentials reproducible. Restore the Age identity before the
  # first rebuild of a fresh installation so sops-nix can create this user.
  users = {
    mutableUsers = false;
    groups.plugdev = { };
    users.${machine.username} = {
      isNormalUser = true;
      description = "Paul Fleming";
      hashedPasswordFile = config.sops.secrets."laufan-password".path;
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
    (mkScript {
      name = "google-chrome-fullscreen";
      runtimeInputs = [ google-chrome ];
    })

    rebuild
    update

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
    # AI coding agents track nixpkgs-unstable. The overnight updater can stage
    # a new input revision, but switching it still requires manual approval.
    unstablePkgs.claude-code
    cliphist
    curl
    fd
    libfido2
    gh
    git
    google-chrome
    drm_info
    edid-decode
    grim
    jq
    libdrm
    libnotify
    neovim
    nodejs
    nwg-displays
    pavucontrol
    unstablePkgs.pi-coding-agent
    playerctl
    ripgrep
    rofi
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
