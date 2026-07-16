{ config, lib, pkgs, unstablePkgs, ... }:

let
  theme = import ./theme.nix;
  mkScript = (import ./lib/scripts.nix).mkShellApplication pkgs;

  cleanTuigreet = pkgs.tuigreet.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or []) ++ [
      ./config/patches/tuigreet-filter-fingerprint-info.patch
    ];
  });

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
    path = ./config/scripts/delayed-nixos-update.sh;
  };

  mkNixosUpdateCheckService = { description, scope, mode ? "check", acOnly ? false }: {
    inherit description;
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      NIX_CONFIG = ''
        max-jobs = 1
        cores = 2
      '';
    };
    unitConfig = lib.optionalAttrs acOnly {
      ConditionACPower = true;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update ${mode}${lib.optionalString (mode == "check") " ${scope}"}";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
    };
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
      extra-substituters = [
        "https://cache.garnix.io"
      ];
      extra-trusted-public-keys = [
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      ];
    };
    # The bounded generation-pruning policy below handles system-profile GC.
    gc.automatic = false;
  };

  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Show normal boot/startup status while diagnosing login/startup issues.
  boot.consoleLogLevel = 4;
  boot.initrd.verbose = true;
  boot.kernelParams = [
    "udev.log_level=info"
    "rd.udev.log_level=info"
    "systemd.show_status=true"
    "rd.systemd.show_status=true"
  ];
  # Load the display driver in the initrd for an earlier, smoother framebuffer handoff.
  boot.initrd.kernelModules = [ "amdgpu" ];
  # Make the Qualcomm Wi-Fi device appear reliably after generation switches/reboots.
  boot.kernelModules = [ "ath11k_pci" ];

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
  programs.nm-applet.enable = false;
  networking.firewall.enable = true;
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

  # Enable fingerprint login for greetd/tuigreet. The patched tuigreet package
  # filters fprintd's instructional PAM info messages from the visible prompt.
  security.pam.services.greetd.fprintAuth = true;
  security.pam.services.greetd.enableGnomeKeyring = true;
  # Hyprlock uses its native fingerprint support, so keep PAM fingerprint off
  # there to avoid duplicate/serial fingerprint handling. Password stays fallback.
  security.pam.services.hyprlock.fprintAuth = false;

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

  users.groups.plugdev = {};

  users.users.laufan = {
    isNormalUser = true;
    description = "Paul Fleming";
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

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    GTK_THEME = theme.appearance.gtkThemeEnv;
  };

  programs.firefox.enable = false;
  programs.command-not-found.enable = false;
  programs.nix-index.enable = true;

  systemd.services.delayed-nixos-update = mkNixosUpdateCheckService {
    description = "Check and build NixOS flake updates for manual approval";
    mode = "catch-up";
    scope = "all";
    acOnly = true;
  };

  systemd.services.nixos-update-check-all = mkNixosUpdateCheckService {
    description = "Check and build updates for all NixOS flake inputs";
    scope = "all";
  };

  systemd.services.nixos-update-check-apps = mkNixosUpdateCheckService {
    description = "Check and build nixpkgs-unstable updates for Codex, Pi, and Claude";
    scope = "apps";
  };

  systemd.services.nixos-update-catchup = mkNixosUpdateCheckService {
    description = "Catch up a missed overnight NixOS update check when on AC power";
    mode = "catch-up";
    scope = "all";
    acOnly = true;
  };

  systemd.services.nixos-update-approve = {
    description = "Apply a checked NixOS flake update after manual approval";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${delayedNixosUpdate}/bin/delayed-nixos-update approve";
    };
  };

  systemd.timers.delayed-nixos-update = {
    description = "Run overnight NixOS update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      AccuracySec = "15m";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.timers.nixos-update-catchup = {
    description = "Retry missed overnight NixOS update checks when AC power is available";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      AccuracySec = "1m";
      RandomizedDelaySec = "2m";
    };
  };

  systemd.services.prune-nixos-generations = {
    description = "Prune NixOS generations with bounded recent, weekly, and monthly retention";
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
# git-hash-padding: 1
