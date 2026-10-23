{
  config,
  lib,
  ...
}:

let
  # Evaluation-time package metadata, carried by each immutable generation. Reading
  # Updates must never evaluate a flake, realise a derivation or contact upstream.
  github = repo: tag_prefix: {
    provider = "github";
    inherit repo tag_prefix;
  };
  archive = project: {
    provider = "archive";
    inherit project;
  };
  gnome = project: {
    provider = "gnome";
    inherit project;
  };
  # Explicit upstream/channel identities, not guesses from pname, homepage or a
  # pending Nix target. Unsupported packages remain unknown. A package may carry
  # a reviewed passthru.shelllistReleaseSource override using this same schema.
  sources = {
    # Reviewed stable archive catalogues; the worker allowlists these identities.
    # Do not map Bash's base tarball: it omits the separately published patchlevel.
    acl = archive "acl";
    attr = archive "attr";
    libfido2 = archive "libfido2";
    coreutils-full = archive "coreutils";
    cpio = archive "cpio";
    diffutils = archive "diffutils";
    findutils = archive "findutils";
    gawk = archive "gawk";
    glibc = archive "glibc";
    glibc-locales = archive "glibc";
    gnugrep = archive "grep";
    gnused = archive "sed";
    gnutar = archive "tar";
    gzip = archive "gzip";
    nano = archive "nano";
    ncurses = archive "ncurses";
    patch = archive "patch";
    texinfo-interactive = archive "texinfo";
    time = archive "time";
    wget = archive "wget";
    which = archive "which";
    adwaita-icon-theme = gnome "adwaita-icon-theme";
    gnome-keyring = gnome "gnome-keyring";
    # GitHub mappings require actual stable release objects, not just git tags.
    adwaita-qt = github "FedoraQt/adwaita-qt" "";
    android-tools = github "nmeum/android-tools" "";
    bibata-cursors = github "ful1e5/Bibata_Cursor" "v";
    blueman = github "blueman-project/blueman" "";
    bluez = github "bluez/bluez" "";
    brightnessctl = github "Hummer12007/brightnessctl" "";
    cups = github "OpenPrinting/cups" "v";
    dbus-broker = github "bus1/dbus-broker" "v";
    dosfstools = github "dosfstools/dosfstools" "v";
    fwupd = github "fwupd/fwupd" "";
    hyprland = github "hyprwm/Hyprland" "v";
    iputils = github "iputils/iputils" "";
    linux-pam = github "linux-pam/linux-pam" "v";
    nix-index = github "nix-community/nix-index" "v";
    nodejs = github "nodejs/node" "v";
    shadow = github "shadow-maint/shadow" "";
    sudo = github "sudo-project/sudo" "v";
    systemd = github "systemd/systemd" "v";
    xz = github "tukaani-project/xz" "v";
    zstd = github "facebook/zstd" "v";
    btop = github "aristocratos/btop" "v";
    direnv = github "direnv/direnv" "v";
    hyprlock = github "hyprwm/hyprlock" "v";
    hyprpaper = github "hyprwm/hyprpaper" "v";
    yazi = github "sxyazi/yazi" "v";
    # The vendor calls its stable channel beta; releases/latest is authoritative.
    zen-browser = github "zen-browser/desktop" "";
    google-chrome = {
      provider = "chrome-stable";
    };
    vscode = {
      provider = "vscode-stable";
    };
    fd = github "sharkdp/fd" "v";
    gh = github "cli/cli" "v";
    jq = github "jqlang/jq" "jq-";
    neovim = github "neovim/neovim" "v";
    ripgrep = github "BurntSushi/ripgrep" "";
    satty = github "Satty-org/Satty" "v";
    playerctl = github "altdesktop/playerctl" "v";
    wl-clipboard = github "bugaevc/wl-clipboard" "v";
    pi-coding-agent = github "earendil-works/pi" "v";
    t3code = github "pingdotgg/t3code" "v";
  };
  packages =
    scope: values:
    map (
      package:
      let
        name = package.pname or (lib.getName package);
        source = package.passthru.shelllistReleaseSource or (sources.${name} or null);
      in
      {
        inherit scope name;
        version = package.version or null;
      }
      // lib.optionalAttrs (source != null) { release_source = source; }
    ) values;
  inventory = lib.unique (
    packages "system" config.environment.systemPackages
    ++ lib.concatLists (
      lib.mapAttrsToList (user: home: packages "user:${user}" home.home.packages) (
        config.home-manager.users or { }
      )
    )
  );
in
{
  environment.etc."shelllist/application-inventory.json".text = builtins.toJSON {
    schema_version = 1;
    packages = inventory;
  };
}
