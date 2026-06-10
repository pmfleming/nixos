{ config, lib, pkgs, ... }:

{
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;
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

  security.pam.services.hyprlock = { };
  security.pam.services.greetd.enableGnomeKeyring = true;

  fonts = {
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      font-awesome
      noto-fonts
      noto-fonts-color-emoji
    ];
    fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono Nerd Font" ];
      sansSerif = [ "Noto Sans" ];
      serif = [ "Noto Serif" ];
    };
  };

  users.users.laufan = {
    isNormalUser = true;
    description = "Paul Fleming";
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    GTK_THEME = "Adwaita:dark";
    GIT_EDITOR = "code --wait";
  };

  programs.firefox.enable = false;
  programs.command-not-found.enable = false;
  programs.nix-index.enable = true;

  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "google-chrome-fullscreen" ''
      exec ${google-chrome}/bin/google-chrome-stable --start-fullscreen "$@"
    '')

    adwaita-icon-theme
    adwaita-qt
    bibata-cursors
    brightnessctl
    cliphist
    curl
    fd
    libfido2
    gh
    git
    google-chrome
    grim
    jq
    libnotify
    neovim
    networkmanagerapplet
    nodejs
    nwg-displays
    pavucontrol
    pi-coding-agent
    playerctl
    ripgrep
    rofi
    slurp
    spotify
    swaynotificationcenter
    swappy
    thunar
    tree
    unzip
    vscode
    wget
    wl-clipboard
  ];

  system.stateVersion = "26.05";
}
