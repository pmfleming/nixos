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
          ({ lib, ... }: {
            hardware.bluetooth.enable = lib.mkForce false;
            services.blueman.enable = lib.mkForce false;
            services.power-profiles-daemon.enable = lib.mkForce false;

            image.modules.hyperv = {
              boot.loader.systemd-boot.enable = lib.mkForce false;
              boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
              virtualisation.diskSize = 64 * 1024;
              image.fileName = "nixos-hyperv.vhdx";
              environment.etc."nixos".source = ./.;
              users.users.laufan.initialPassword = "nixos";

              fileSystems."/" = lib.mkForce {
                device = "/dev/disk/by-label/nixos";
                autoResize = true;
                fsType = "ext4";
              };
              fileSystems."/boot" = lib.mkForce {
                device = "/dev/disk/by-label/ESP";
                fsType = "vfat";
              };
            };
          })
        ];
      };

      packages.${system}.hyperv-vhdx =
        self.nixosConfigurations.hyperv.config.system.build.images.hyperv;
    };
}
