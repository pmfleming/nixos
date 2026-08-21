{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    hyprland-guiutils.url = "github:hyprwm/hyprland-guiutils";
    hyprland-guiutils.inputs.nixpkgs.follows = "nixpkgs";
    zen-browser.url = "github:youwen5/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    # Automatic update lanes never advance these machine-local inputs.
    nm-daemon.url = "git+file:///home/laufan/Projects/nm-daemon?ref=main";
    nm-daemon.inputs.nixpkgs.follows = "nixpkgs";
    bt-daemon.url = "git+file:///home/laufan/Projects/bt-daemon?ref=main";
    bt-daemon.inputs.nixpkgs.follows = "nixpkgs";
    clip-daemon.url = "git+file:///home/laufan/Projects/clip-daemon?ref=main";
    clip-daemon.inputs.nixpkgs.follows = "nixpkgs";
    app-daemon.url = "git+file:///home/laufan/Projects/app-daemon?ref=main";
    app-daemon.inputs.nixpkgs.follows = "nixpkgs";
    bar-daemon.url = "git+file:///home/laufan/Projects/bar-daemon?ref=main";
    bar-daemon.inputs.nixpkgs.follows = "nixpkgs";

    shelllist = {
      url = "git+file:///home/laufan/Projects/shelllist?ref=main";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nm-daemon.follows = "nm-daemon";
        bt-daemon.follows = "bt-daemon";
        clip-daemon.follows = "clip-daemon";
        app-daemon.follows = "app-daemon";
        bar-daemon.follows = "bar-daemon";
      };
    };

    scratchpad.url = "git+file:///home/laufan/Projects/scratchpad?ref=master";
    scratchpad.inputs.nixpkgs.follows = "nixpkgs";
    ts-react-quality-lens.url = "git+file:///home/laufan/Projects/ts-react-quality-lens?ref=main";
    ts-react-quality-lens.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      machine = {
        system = "x86_64-linux";
        hostName = "thinkpad";
        username = "laufan";
        homeDirectory = "/home/laufan";
        configDirectory = "/etc/nixos";
        localProjects = [
          "app-daemon"
          "bar-daemon"
          "bt-daemon"
          "clip-daemon"
          "nm-daemon"
          "scratchpad"
          "shelllist"
          "ts-react-quality-lens"
        ];
      };
      inherit (machine) system;
      pkgs = nixpkgs.legacyPackages.${system};
      unstablePkgs = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [
            "claude-code"
            "codex"
            "pi-coding-agent"
            "t3code"
          ];
      };
      connectParityProbe = inputs.nm-daemon.packages.${system}.connectParityProbe;
      specialArgs = { inherit inputs machine unstablePkgs; };
      homeManagerModule = {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          extraSpecialArgs = specialArgs;
          users.${machine.username} = import ./home.nix;
        };
      };
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        nix =
          pkgs.runCommand "nix-quality-check"
            {
              nativeBuildInputs = with pkgs; [
                deadnix
                findutils
                nixfmt
                statix
              ];
            }
            ''
              find ${self} -type f -name '*.nix' -exec nixfmt --check {} +
              deadnix --fail ${self}
              statix check ${self}
              touch $out
            '';

        shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          find ${self}/config/scripts -type f -name '*.sh' \
            -exec shellcheck -s bash -x -e SC1091 {} +
          touch $out
        '';

        updater-state =
          pkgs.runCommand "delayed-updater-state-tests"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                git
                jq
              ];
            }
            ''
              bash ${self}/config/scripts/tests/delayed-nixos-update.sh \
                ${self}/config/scripts/delayed-nixos-update.sh
              touch $out
            '';

        generation-retention =
          pkgs.runCommand "generation-retention-tests"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                gawk
              ];
            }
            ''
              bash ${self}/config/scripts/tests/prune-nixos-generations.sh \
                ${self}/config/scripts/prune-nixos-generations.sh
              touch $out
            '';

        pi-extensions =
          pkgs.runCommand "pi-extension-tests"
            {
              nativeBuildInputs = with pkgs; [
                nodejs
                typescript
              ];
            }
            ''
              cp -R ${self}/config/pi ./pi
              chmod -R u+w ./pi

              vendor=${unstablePkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules
              mkdir -p node_modules/@earendil-works
              for entry in "$vendor"/*; do
                name="$(basename "$entry")"
                if [ "$name" != @earendil-works ]; then
                  ln -s "$entry" "node_modules/$name"
                fi
              done
              for entry in "$vendor/@earendil-works"/*; do
                ln -s "$entry" "node_modules/@earendil-works/$(basename "$entry")"
              done
              ln -s ${unstablePkgs.pi-coding-agent}/lib/node_modules/pi-monorepo \
                node_modules/@earendil-works/pi-coding-agent

              tsc --project ./pi/tsconfig.json
              node --experimental-strip-types --test ./pi/tests/*.test.ts
              touch $out
            '';

        config-files =
          pkgs.runCommand "desktop-config-tests"
            {
              nativeBuildInputs = with pkgs; [
                lua
                (python3.withPackages (pythonPackages: [ pythonPackages.json5 ]))
              ];
            }
            ''
              python - <<'PY'
              import json
              from pathlib import Path

              import json5

              root = Path("${self}/config")
              for path in root.rglob("*.json"):
                  with path.open(encoding="utf-8") as source:
                      json.load(source)
              for path in root.rglob("*.jsonc"):
                  with path.open(encoding="utf-8") as source:
                      json5.load(source)
              PY

              cp -R ${self}/config/hypr ./hypr
              chmod -R u+w ./hypr
              substituteInPlace ./hypr/hyprland.lua \
                --replace-fail '@UWSM_APP@' '/bin/true' \
                --replace-fail '@SCRATCHPAD@' '/bin/true' \
                --replace-fail '@MONITOR_SCALE@' '1' \
                --replace-fail '@RADIUS_INT@' '1' \
                --replace-fail '@ACCENT_BARE@' '000000' \
                --replace-fail '@BORDER_DIM_BARE@' '000000' \
                --replace-fail '@HYPRLAND_ENV@' '-- generated environment'
              find ./hypr -type f -name '*.lua' -exec luac -p {} +
              touch $out
            '';
      };

      packages.${system} = { inherit connectParityProbe; };

      apps.${system}.connectParityProbe = {
        type = "app";
        program = "${connectParityProbe}/bin/nm-daemon-connect-parity-probe";
        meta.description = "Compare nm-daemon and nmcli Wi-Fi connection behavior";
      };

      nixosConfigurations.${machine.hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        inherit specialArgs;
        modules = [
          ./configuration.nix
          inputs.sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };
    };
}
