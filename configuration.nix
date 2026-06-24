{ config, lib, pkgs, unstablePkgs, ... }:

let
  theme = import ./theme.nix;
  mkScript = (import ./lib/scripts.nix).mkShellApplication pkgs;

  delayedNixosUpdate = mkScript {
    name = "delayed-nixos-update";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      jq
      nix
      nixos-rebuild
    ];
    path = ./config/scripts/delayed-nixos-update.sh;
  };

  pruneNixosGenerations = mkScript {
    name = "prune-nixos-generations";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.gawk
    ];
    path = ./config/scripts/prune-nixos-generations.sh;
  };
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };
    # Custom generation-pruning timer below handles GC; age-based GC would remove milestone generations.
    gc.automatic = false;
  };

  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "thinkpad";
  networking.networkmanager = {
    enable = true;
    settings.connectivity = {
      enabled = true;
      uri = "http://nmcheck.gnome.org/check_network_status.txt";
      response = "NetworkManager is online";
      interval = 300;
    };
  };
  networking.firewall.enable = true;

  time.timeZone = "Europe/Amsterdam";

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
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${config.programs.hyprland.package}/bin/start-hyprland";
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
  # Fingerprint reader support. PAM keeps the normal password as a fallback.
  services.fprintd.enable = true;
  security.polkit.enable = true;
  security.rtkit.enable = true;

  services.printing.enable = true;
  services.openssh.enable = false;
  services.flatpak.enable = true;

  # FIDO2/WebAuthn security key support for browser passkeys.
  services.udev.packages = with pkgs; [
    libfido2
  ];

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.blueman.enable = true;

  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  hardware.enableRedistributableFirmware = true;
  zramSwap.enable = true;

  services.power-profiles-daemon.enable = true;
  services.logind.settings.Login = {
    HandlePowerKey = "suspend";
    HandleLidSwitch = "suspend";
    HandleLidSwitchDocked = "ignore";
  };

  # Hyprlock has native fingerprint support, so keep its PAM stack password-only.
  # This avoids PAM's serial fingerprint-then-password delay on the lock screen.
  security.pam.services.hyprlock.fprintAuth = false;
  security.pam.services.greetd.enableGnomeKeyring = true;

  fonts = {
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      font-awesome
      noto-fonts
      noto-fonts-color-emoji
    ];
    fontconfig.defaultFonts = {
      monospace = [ theme.fonts.mono ];
      sansSerif = [ theme.fonts.sans ];
      serif = [ theme.fonts.serif ];
    };
  };

  users.users.laufan = {
    isNormalUser = true;
    description = "Paul Fleming";
    extraGroups = [
      "audio"
      "input"
      "kvm"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    GTK_THEME = theme.appearance.gtkThemeEnv;
  };

  programs.firefox.enable = false;
  programs.command-not-found.enable = false;
  programs.nix-index.enable = true;

  systemd.services.delayed-nixos-update = {
    description = "Update nixpkgs-unstable immediately and other flake inputs after 3 days";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update";
    };
  };

  systemd.timers.delayed-nixos-update = {
    description = "Run delayed NixOS flake updater";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
  };

  systemd.services.prune-nixos-generations = {
    description = "Prune NixOS generations, keeping latest 5 plus generation 1 and every 10th";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pruneNixosGenerations}/bin/prune-nixos-generations";
    };
  };

  systemd.timers.prune-nixos-generations = {
    description = "Run NixOS generation pruning once per day";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  environment.systemPackages = with pkgs; [
    (mkScript {
      name = "google-chrome-fullscreen";
      runtimeInputs = [ google-chrome ];
      path = ./config/scripts/google-chrome-fullscreen.sh;
    })

    (mkScript {
      name = "rebuild";
      runtimeInputs = [ git nix nixos-rebuild ];
      path = ./config/scripts/rebuild.sh;
    })

    (mkScript {
      name = "update";
      runtimeInputs = [ nix nixos-rebuild ];
      path = ./config/scripts/update.sh;
    })

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
    swappy
    tree
    unzip
    vscode
    wget
    wl-clipboard
    xdg-utils
  ];

  system.stateVersion = "26.05";
}
# git-hash-padding: 1
