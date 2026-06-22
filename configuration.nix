{ config, lib, pkgs, unstablePkgs, ... }:

let
  theme = import ./theme.nix;

  delayedNixosUpdate = pkgs.writeShellApplication {
    name = "delayed-nixos-update";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      jq
      nix
      nixos-rebuild
    ];
    text = ''
      set -euo pipefail

      flake_dir=/etc/nixos
      flake_attr=thinkpad
      delay_seconds=$((3 * 24 * 60 * 60))
      state_dir=/var/lib/nixos-delayed-updates
      candidate_lock="$state_dir/candidate-flake.lock"
      first_seen_file="$state_dir/first-seen"
      pending_switch_file="$state_dir/current-lock-needs-switch"
      ready_file=/run/nixos-updates-available

      # Keep fast-moving AI coding tools current without waiting for the
      # normal delayed-update window used by the rest of the flake inputs.
      immediate_inputs=(nixpkgs-unstable)
      immediate_inputs_json='["nixpkgs-unstable"]'

      strip_immediate_inputs() {
        jq --argjson inputs "$immediate_inputs_json" '
          reduce $inputs[] as $input (.;
            if .nodes.root.inputs[$input] then
              del(.nodes[.nodes.root.inputs[$input]])
              | del(.nodes.root.inputs[$input])
            else
              .
            end
          )
        ' "$1"
      }

      merge_immediate_inputs_from_current() {
        jq --argjson inputs "$immediate_inputs_json" -s '
          .[0] as $delayed | .[1] as $current |
          reduce $inputs[] as $input ($delayed;
            if $current.nodes.root.inputs[$input] then
              .nodes.root.inputs[$input] = $current.nodes.root.inputs[$input]
              | .nodes[$current.nodes.root.inputs[$input]] = $current.nodes[$current.nodes.root.inputs[$input]]
            else
              del(.nodes.root.inputs[$input])
            end
          )
        ' "$1" "$2"
      }

      switch_current_if_pending() {
        if [ -f "$pending_switch_file" ]; then
          if nixos-rebuild switch --flake "$flake_dir#$flake_attr"; then
            rm -f "$pending_switch_file"
          fi
        fi
      }

      install_lock() {
        # This service runs as root, so a plain cp would leave flake.lock
        # root-owned and break later user-level git operations in the checkout.
        # Match the flake directory's existing ownership instead.
        cp "$1" "$flake_dir/flake.lock"
        chown --reference="$flake_dir" "$flake_dir/flake.lock"
      }

      mkdir -p "$state_dir"
      rm -f "$ready_file"

      tmp_dir="$(mktemp -d)"
      trap 'rm -rf "$tmp_dir"' EXIT

      immediate_lock="$tmp_dir/immediate-flake.lock"
      if nix flake update "''${immediate_inputs[@]}" --flake "$flake_dir" --output-lock-file "$immediate_lock" >/dev/null 2>&1; then
        if ! cmp -s "$flake_dir/flake.lock" "$immediate_lock"; then
          install_lock "$immediate_lock"
          touch "$pending_switch_file"
        fi
      fi

      if ! nix flake update --flake "$flake_dir" --output-lock-file "$tmp_dir/flake.lock" >/dev/null 2>&1; then
        switch_current_if_pending
        exit 0
      fi

      current_comparable="$tmp_dir/current-comparable-flake.lock"
      updated_comparable="$tmp_dir/updated-comparable-flake.lock"
      strip_immediate_inputs "$flake_dir/flake.lock" > "$current_comparable"
      strip_immediate_inputs "$tmp_dir/flake.lock" > "$updated_comparable"

      if cmp -s "$current_comparable" "$updated_comparable"; then
        rm -f "$candidate_lock" "$first_seen_file" "$ready_file"
        switch_current_if_pending
        exit 0
      fi

      now="$(date +%s)"

      if [ -f "$candidate_lock" ]; then
        candidate_comparable="$tmp_dir/candidate-comparable-flake.lock"
        strip_immediate_inputs "$candidate_lock" > "$candidate_comparable"
      fi

      if [ ! -f "$candidate_lock" ] || ! cmp -s "$candidate_comparable" "$updated_comparable"; then
        cp "$tmp_dir/flake.lock" "$candidate_lock"
        printf '%s\n' "$now" > "$first_seen_file"
        switch_current_if_pending
        exit 0
      fi

      first_seen="$(cat "$first_seen_file" 2>/dev/null || printf '%s' "$now")"
      age=$((now - first_seen))

      if [ "$age" -lt "$delay_seconds" ]; then
        switch_current_if_pending
        exit 0
      fi

      merged_lock="$tmp_dir/merged-flake.lock"
      merge_immediate_inputs_from_current "$candidate_lock" "$flake_dir/flake.lock" > "$merged_lock"

      touch "$ready_file"
      install_lock "$merged_lock"
      touch "$pending_switch_file"

      if nixos-rebuild switch --flake "$flake_dir#$flake_attr"; then
        rm -f "$candidate_lock" "$first_seen_file" "$pending_switch_file" "$ready_file"
      fi
    '';
  };

  pruneNixosGenerations = pkgs.writeShellApplication {
    name = "prune-nixos-generations";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      set -euo pipefail

      profile=/nix/var/nix/profiles/system
      keep_recent=5
      keep_every=10

      refresh_boot_entries() {
        echo "Refreshing systemd-boot entries"
        /run/current-system/bin/switch-to-configuration boot
      }

      mapfile -t gens < <(
        nix-env --profile "$profile" --list-generations \
          | awk '{print $1}' \
          | sort -n
      )

      total="''${#gens[@]}"
      if (( total <= keep_recent )); then
        echo "Keeping all $total NixOS generations"
        refresh_boot_entries
        exit 0
      fi

      profile_current="$(readlink -f "$profile" 2>/dev/null || true)"
      run_current="$(readlink -f /run/current-system 2>/dev/null || true)"
      run_booted="$(readlink -f /run/booted-system 2>/dev/null || true)"

      keep=()
      delete=()

      for idx in "''${!gens[@]}"; do
        gen="''${gens[$idx]}"
        link="$(readlink -f "$profile-$gen-link" 2>/dev/null || true)"
        keep_gen=0

        # Keep newest N generations.
        if (( idx >= total - keep_recent )); then
          keep_gen=1
        fi

        # Keep generation 1 and every 10th generation: 10, 20, 30, ...
        if (( gen == 1 || gen % keep_every == 0 )); then
          keep_gen=1
        fi

        # Never delete the current or booted system, even if it falls outside the policy.
        if [[ -n "$link" && -n "$profile_current" && "$link" == "$profile_current" ]]; then
          keep_gen=1
        fi
        if [[ -n "$link" && -n "$run_current" && "$link" == "$run_current" ]]; then
          keep_gen=1
        fi
        if [[ -n "$link" && -n "$run_booted" && "$link" == "$run_booted" ]]; then
          keep_gen=1
        fi

        if (( keep_gen )); then
          keep+=("$gen")
        else
          delete+=("$gen")
        fi
      done

      echo "Keeping NixOS generations: ''${keep[*]}"

      if (( ''${#delete[@]} )); then
        echo "Deleting NixOS generations: ''${delete[*]}"
        nix-env --profile "$profile" --delete-generations "''${delete[@]}"
        nix-store --gc
      else
        echo "No NixOS generations to delete"
      fi

      refresh_boot_entries
    '';
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
    (writeShellScriptBin "google-chrome-fullscreen" ''
      exec ${google-chrome}/bin/google-chrome-stable --start-fullscreen "$@"
    '')

    (writeShellApplication {
      name = "rebuild";
      runtimeInputs = [ git nix nixos-rebuild ];
      text = ''
        set -euo pipefail
        flake_dir=/etc/nixos
        flake_attr=''${1:-thinkpad}

        cd "$flake_dir"
        nix flake check "$flake_dir" --no-build
        sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr"
      '';
    })

    (writeShellApplication {
      name = "update";
      runtimeInputs = [ nix nixos-rebuild ];
      text = ''
        set -euo pipefail
        flake_dir=/etc/nixos
        flake_attr=''${1:-thinkpad}

        cd "$flake_dir"
        nix flake update
        nix flake check "$flake_dir" --no-build
        sudo nixos-rebuild switch --flake "$flake_dir#$flake_attr"
      '';
    })

    (writeShellApplication {
      name = "rollback";
      runtimeInputs = [ nixos-rebuild ];
      text = ''
        sudo nixos-rebuild switch --rollback
      '';
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
  ];

  system.stateVersion = "26.05";
}
# git-hash-padding: 1
