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

    # Automatic updates never advance these machine-local inputs.
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
      updateAiTools = (import ./lib/scripts.nix).mkScriptFrom pkgs ./config/scripts {
        name = "update-ai-tools";
        runtimeInputs = with pkgs; [
          coreutils
          diffutils
          git
          gnutar
          jq
          libnotify
          nix
          procps
          util-linux
        ];
        replacements = {
          "@USERNAME@" = machine.username;
        };
      };
      aiTools = pkgs.buildEnv {
        name = "ai-coding-tools";
        paths = with unstablePkgs; [
          claude-code
          codex
          pi-coding-agent
          t3code
        ];
        pathsToLink = [ "/bin" ];
      };
      specialArgs = {
        inherit
          inputs
          machine
          unstablePkgs
          updateAiTools
          ;
      };
      homeManagerModule = {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          extraSpecialArgs = specialArgs;
          users.${machine.username} = import ./home.nix;
        };
      };
      mkCheck =
        name: nativeBuildInputs: script:
        pkgs.runCommand name { inherit nativeBuildInputs; } (script + "\ntouch $out\n");
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        nix =
          mkCheck "nix-quality-check"
            (with pkgs; [
              deadnix
              findutils
              nixfmt
              statix
            ])
            ''
              find ${self} -type f -name '*.nix' -exec nixfmt --check {} +
              deadnix --fail ${self}
              statix check ${self}
            '';

        shellcheck = mkCheck "shellcheck" [ pkgs.shellcheck ] ''
          find ${self}/config/scripts -type f -name '*.sh' \
            -exec shellcheck -s bash -x -e SC1091 {} +
        '';

        monitor-auto =
          mkCheck "monitor-auto-tests"
            (with pkgs; [
              bash
              coreutils
              gnugrep
            ])
            ''
              bash ${self}/config/scripts/tests/hypr-monitor-auto.sh \
                ${self}/config/scripts/hypr-monitor-auto.sh
            '';

        updater-state =
          mkCheck "delayed-updater-state-tests"
            (with pkgs; [
              bash
              coreutils
              git
              jq
            ])
            ''
              bash ${self}/config/scripts/tests/delayed-nixos-update.sh \
                ${self}/config/scripts/delayed-nixos-update.sh
            '';

        ai-tools-updater-state =
          mkCheck "ai-tools-updater-state-tests"
            (with pkgs; [
              bash
              coreutils
              diffutils
              jq
            ])
            ''
              bash ${self}/config/scripts/tests/update-ai-tools.sh \
                ${self}/config/scripts/update-ai-tools.sh
            '';

        ai-tools-updater-runtime = mkCheck "ai-tools-updater-runtime-test" [ ] ''
          ${pkgs.coreutils}/bin/env -i PATH=/missing \
            ${updateAiTools}/bin/update-ai-tools check-runtime
        '';

        generation-retention =
          mkCheck "generation-retention-tests"
            (with pkgs; [
              bash
              coreutils
              gawk
            ])
            ''
              bash ${self}/config/scripts/tests/prune-nixos-generations.sh \
                ${self}/config/scripts/prune-nixos-generations.sh
            '';

        pi-extensions =
          mkCheck "pi-extension-tests"
            (with pkgs; [
              nodejs
              typescript
            ])
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
            '';

        config-files =
          mkCheck "desktop-config-tests"
            (with pkgs; [
              lua
              (python3.withPackages (pythonPackages: [ pythonPackages.json5 ]))
            ])
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
                --replace-fail '@BORDER_DIM_BARE@' '000000'
              find ./hypr -type f -name '*.lua' -exec luac -p {} +
            '';
      };

      packages.${system} = {
        inherit aiTools connectParityProbe;
      };

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
