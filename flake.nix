{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Isolated HDMI recovery candidates; the base OS keeps its existing pin.
    nixpkgs-display.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    hyprland-guiutils.url = "github:hyprwm/hyprland-guiutils";
    hyprland-guiutils.inputs.nixpkgs.follows = "nixpkgs";
    zen-browser.url = "github:youwen5/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    # CO-DEVELOPMENT INVARIANT: all five daemons use ONE current local framework.
    # local-build snapshots tracked worktrees (including dirty files) once per
    # invocation. Never add refs/revisions, private framework copies, or rely on
    # persistent local-project locks. Checks and deployment use the same snapshot.
    daemon-framework.url = "git+file:///home/laufan/Projects/daemon-framework";
    daemon-framework.inputs.nixpkgs.follows = "nixpkgs";
    update-daemon.url = "git+file:///home/laufan/Projects/update-daemon";

    nm-daemon = {
      url = "git+file:///home/laufan/Projects/nm-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
      };
    };
    bt-daemon = {
      url = "git+file:///home/laufan/Projects/bt-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
      };
    };
    clip-daemon = {
      url = "git+file:///home/laufan/Projects/clip-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
      };
    };
    app-daemon = {
      url = "git+file:///home/laufan/Projects/app-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
      };
    };
    shelllist-hyprland.url = "git+file:///home/laufan/Projects/shelllist-hyprland";
    shelllist-hyprland.inputs.nixpkgs.follows = "nixpkgs";
    bar-daemon = {
      url = "git+file:///home/laufan/Projects/bar-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
        hyprlandIpc.follows = "shelllist-hyprland";
      };
    };

    shelllist = {
      url = "git+file:///home/laufan/Projects/shelllist";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemon-framework.follows = "daemon-framework";
        shelllist-hyprland.follows = "shelllist-hyprland";
        nm-daemon.follows = "nm-daemon";
        bt-daemon.follows = "bt-daemon";
        clip-daemon.follows = "clip-daemon";
        app-daemon.follows = "app-daemon";
        bar-daemon.follows = "bar-daemon";
      };
    };

    scratchpad.url = "git+file:///home/laufan/Projects/scratchpad";
    scratchpad.inputs.nixpkgs.follows = "nixpkgs";
    ts-react-quality-lens.url = "git+file:///home/laufan/Projects/ts-react-quality-lens";
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
        # Derive the set from declarations so updater exclusions cannot drift.
        localProjects = builtins.attrNames (
          nixpkgs.lib.filterAttrs (
            _: spec: nixpkgs.lib.hasPrefix "git+file:" (spec.url or "")
          ) (import ./flake.nix).inputs
        );
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
      updateWorker = inputs.update-daemon.lib.mkPackage {
        inherit pkgs;
        inherit (machine) hostName username;
        manualInputs = machine.localProjects;
        deploymentLockHelper = (import ./lib/deployment-lock.nix { inherit pkgs; }).helper;
        localBuildHelper = "${inputs.daemon-framework}/tools/local-build.py";
        sourceStateHelper = ./config/scripts/rebuild-source-state.py;
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
          updateWorker
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

      # `flake check` is not recursive. Explicitly include the entire shared
      # framework + consumer + Shelllist contract matrix before deployment.
      checks.${system} =
        nixpkgs.lib.mapAttrs' (
          name: value: nixpkgs.lib.nameValuePair "shelllist-${name}" value
        ) inputs.shelllist.checks.${system}
        // {
          framework-workspace = inputs.daemon-framework.checks.${system}.workspace;
          local-build-policy = inputs.daemon-framework.checks.${system}.localBuild;
          rebuild-sources =
            mkCheck "rebuild-source-identity-tests"
              (with pkgs; [
                bash
                coreutils
                findutils
                git
                jq
                python3
                util-linux
              ])
              ''
                python3 ${self}/config/scripts/tests/rebuild-sources.py ${self}/config/scripts \
                  ${inputs.update-daemon}/helpers/delayed-nixos-update.sh
                python3 ${self}/config/scripts/tests/rebuild-source-state.py ${self}/config/scripts
              '';
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

          sleep-recovery =
            let
              base = self.nixosConfigurations.${machine.hostName}.config;
              versions = config: {
                kernel = config.boot.kernelPackages.kernel.version;
                hyprland = config.programs.hyprland.package.version;
                portal = config.programs.hyprland.portalPackage.version;
                mesa = config.hardware.graphics.package.version;
                mesa32 = config.hardware.graphics.package32.version;
                aquamarine =
                  (nixpkgs.lib.findFirst (
                    p: (p.pname or "") == "aquamarine"
                  ) (throw "Hyprland must link Aquamarine") config.programs.hyprland.package.buildInputs).version;
              };
              fixture = pkgs.writeText "sleep-recovery.json" (
                builtins.toJSON {
                  idle = base.home-manager.users.${machine.username}.services.hypridle.settings;
                  hyprlandConfig =
                    base.home-manager.users.${machine.username}.xdg.configFile."hypr/hyprland.lua".text;
                  baseline = versions base;
                  candidates = builtins.mapAttrs (_: value: versions value.configuration) base.specialisation;
                }
              );
            in
            mkCheck "sleep-recovery-tests" [ pkgs.python3 ] ''
              python3 ${self}/config/scripts/tests/sleep-recovery.py ${fixture}
            '';

          display-layout-compatibility = mkCheck "display-layout-compatibility" [ pkgs.bash pkgs.gnugrep ] ''
            bash ${self}/config/scripts/tests/display-layout-compatibility.sh ${self}
          '';

          deployment-lock =
            mkCheck "deployment-lock-tests"
              (with pkgs; [
                bash
                coreutils
                util-linux
              ])
              ''
                bash ${self}/config/scripts/tests/deployment-lock.sh \
                  ${self}/config/scripts ${inputs.update-daemon}/helpers/delayed-nixos-update.sh
              '';

          updater-state = updateWorker.tests;

          ai-tools-updater-runtime = mkCheck "ai-tools-updater-runtime-test" [ ] ''
            ${pkgs.coreutils}/bin/env -i PATH=/missing \
              ${updateWorker}/bin/update-worker check-runtime
          '';

          generation-retention =
            mkCheck "generation-retention-tests"
              (with pkgs; [
                bash
                coreutils
                gawk
                util-linux
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
        rebuild = self.nixosConfigurations.${machine.hostName}.config.system.build.rebuild;
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
          ./modules/display-recovery.nix
          inputs.sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };
    };
}
