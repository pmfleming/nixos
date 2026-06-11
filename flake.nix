{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

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
      nixosConfigurations.thinkpad = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs unstablePkgs; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };

      nixosConfigurations.hyperv = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ({ modulesPath, pkgs, ... }: {
            imports = [
              "${modulesPath}/profiles/minimal.nix"
              "${modulesPath}/virtualisation/hyperv-image.nix"
            ];

            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
            nixpkgs.config.allowUnfree = true;

            networking.hostName = "nixos-hyperv";
            networking.networkmanager.enable = true;
            virtualisation.diskSize = 8 * 1024;
            time.timeZone = "Europe/Amsterdam";
            console.keyMap = "us";

            users.users.laufan = {
              isNormalUser = true;
              description = "Paul Fleming";
              initialPassword = "changeme";
              extraGroups = [
                "networkmanager"
                "wheel"
              ];
            };

            services.openssh.enable = true;
            environment.systemPackages = with pkgs; [
              git
              neovim
              ripgrep
              wget
            ];

            system.stateVersion = "26.05";
          })
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };

      packages.${system}.hyperv-vhdx =
        self.nixosConfigurations.hyperv.config.system.build.hypervImage;
    };
}
