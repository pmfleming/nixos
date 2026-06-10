{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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
  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      mkHost = { name, hardware, extraModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            ./configuration.nix
            hardware
            home-manager.nixosModules.home-manager
            {
              networking.hostName = name;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "hm-backup";
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.users.laufan = import ./home.nix;
            }
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations.thinkpad = mkHost {
        name = "thinkpad";
        hardware = ./hardware-configuration.nix;
      };

      nixosConfigurations.hyperv = mkHost {
        name = "nixos-hyperv";
        hardware = ./hardware-hyperv.nix;
        extraModules = [
          ./hosts/hyperv.nix
        ];
      };

      packages.${system}.hyperv-vhdx =
        self.nixosConfigurations.hyperv.config.system.build.images.hyperv;
    };
}
