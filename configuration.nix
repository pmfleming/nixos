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
  mkScript = (import ./lib/scripts.nix).mkShellApplication pkgs;

  cleanTuigreet = pkgs.tuigreet.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./config/patches/tuigreet-filter-fingerprint-info.patch
    ];
  });

  rebuild = mkScript {
    name = "rebuild";
    runtimeInputs = with pkgs; [
      git
      nix
      nixos-rebuild
    ];
    replacements."@FLAKE_ATTR@" = machine.hostName;
    path = ./config/scripts/rebuild.sh;
  };

  update = mkScript {
    name = "update";
    runtimeInputs = [
      pkgs.nix
      rebuild
    ];
    replacements."@FLAKE_ATTR@" = machine.hostName;
    path = ./config/scripts/update.sh;
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
      # Garnix embeds two-hour signed URLs in narinfo; refresh within their lifetime.
      narinfo-cache-positive-ttl = 3600;
      extra-substituters = [
        "https://cache.garnix.io"
      ];
      extra-trusted-public-keys = [
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      ];
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
  programs.nm-applet.enable = false;
  # NetworkManager-wait-online can take ~10s on Wi-Fi while autoconnect/DHCP
  # settle. This does not block graphical login; it only gates units that
  # explicitly wait for network-online.target, such as the update timer service.
  # Keep it enabled so those jobs start with a real network when available.

  time.timeZone = lib.mkDefault "Europe/Amsterdam";
  services.automatic-timezoned.enable = true;

  i18n.defaultLocale = "en_IE.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_IE.UTF-8";
    LC_IDENTIFICATION = "en_IE.UTF-8";
    LC_MEASUREMENT = "en_IE.UTF-8";
    LC_MONETARY = "en_IE.UTF-8";
    LC_NAME = "en_IE.UTF-8";
    LC_NUMERIC = "en_IE.UTF-8";
    LC_PAPER = "en_IE.UTF-8";
    LC_TELEPHONE = "en_IE.UTF-8";
    LC_TIME = "en_IE.UTF-8";
  };

  console.keyMap = "us";

  services.displayManager.gdm.enable = false;
  services.desktopManager.gnome.enable = false;

  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings = {
      default_session = {
        command = "${cleanTuigreet}/bin/tuigreet --time --remember --prompt-padding 0 --cmd ${config.programs.hyprland.package}/bin/start-hyprland";
        user = "greeter";
      };
    };
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
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

  programs.dconf.enable = true;
  services.gnome.gnome-keyring.enable = true;
  # Fingerprint reader support for login and lock-screen biometric auth.
  # The patched tuigreet above filters PAM's instructional fingerprint text.
  services.fprintd.enable = true;

  services.printing.enable = true;
  services.openssh.enable = false;
  services.flatpak.enable = true;

  # FIDO2/WebAuthn security key support for browser passkeys.
  services.udev.packages = with pkgs; [
    libfido2
  ];

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
  services.blueman.enable = true;

  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  zramSwap.enable = true;

  services.power-profiles-daemon.enable = true;
  services.logind.settings.Login = {
    HandlePowerKey = "suspend";
    HandleLidSwitch = "suspend";
    HandleLidSwitchDocked = "ignore";
  };

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

  programs.firefox.enable = false;
  programs.command-not-found.enable = false;
  programs.nix-index.enable = true;

  environment.systemPackages = with pkgs; [
    (mkScript {
      name = "google-chrome-fullscreen";
      runtimeInputs = [ google-chrome ];
      path = ./config/scripts/google-chrome-fullscreen.sh;
    })

    rebuild
    update

    (mkScript {
      name = "rollback";
      runtimeInputs = [ nixos-rebuild ];
      path = ./config/scripts/rollback.sh;
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
