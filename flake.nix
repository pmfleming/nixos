{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Default kernel/display stack; the base OS keeps its existing pin.
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
    bar-daemon = {
      url = "git+file:///home/laufan/Projects/bar-daemon";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemonFramework.follows = "daemon-framework";
      };
    };

    shelllist = {
      url = "git+file:///home/laufan/Projects/shelllist";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        daemon-framework.follows = "daemon-framework";
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
        localBuildHelper = "${inputs.daemon-framework}/tools/local-build.py";
        sourceStateHelper = ./config/scripts/rebuild-source-state.py;
      };
      vendorAiTools = import ./packages/vendor-ai-tools {
        inherit pkgs;
        piExtensions = ./config/pi;
        fallbacks = unstablePkgs;
        inherit (machine) username;
      };
      specialArgs = {
        inherit
          inputs
          machine
          unstablePkgs
          updateWorker
          vendorAiTools
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
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = import ./checks.nix {
        inherit
          self
          inputs
          pkgs
          machine
          unstablePkgs
          updateWorker
          vendorAiTools
          ;
      };

      packages.${system} = {
        inherit connectParityProbe;
        ai-tools-updater = vendorAiTools.updater;
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
