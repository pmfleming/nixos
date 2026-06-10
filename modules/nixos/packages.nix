{ pkgs, ... }:

{
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
}
