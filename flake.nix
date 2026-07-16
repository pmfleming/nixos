{
  description = "ThinkPad NixOS desktop configuration";

  nixConfig = {
    extra-substituters = [
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-guiutils = {
      url = "github:hyprwm/hyprland-guiutils";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    affinity-nix.url = "github:mrshmllow/affinity-nix";

    nm-daemon = {
      url = "git+file:///home/laufan/Projects/nm-daemon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    shelllist = {
      url = "git+file:///home/laufan/Projects/shelllist";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nm-daemon.follows = "nm-daemon";
    };

    scratchpad = {
      url = "github:pmfleming/scratchpad";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ts-react-quality-lens = {
      url = "path:/home/laufan/Projects/ts-react-quality-lens";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      unstablePkgs = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      homeManagerModule = {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.backupFileExtension = "hm-backup";
        home-manager.extraSpecialArgs = { inherit inputs unstablePkgs; };
        home-manager.users.laufan = import ./home.nix;
      };
    in
    {
      packages.${system}.connectParityProbe = inputs.nm-daemon.packages.${system}.connectParityProbe;

      apps.${system}.connectParityProbe = {
        type = "app";
        program = "${inputs.nm-daemon.packages.${system}.connectParityProbe}/bin/nm-daemon-connect-parity-probe";
        meta.description = "Compare nm-daemon and nmcli Wi-Fi connection behavior";
      };

      nixosConfigurations.thinkpad = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs unstablePkgs; };
        modules = [
          ({ ... }: {
            nixpkgs.overlays = [ inputs.affinity-nix.overlays.default ];
          })
          ./configuration.nix
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };
    };
}
