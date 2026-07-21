{
  description = "ThinkPad NixOS desktop configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
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

    # These development inputs are intentionally machine-local. Using git+file
    # lets this host evaluate committed local changes without first pushing them
    # to GitHub; the exact /home/laufan/Projects paths are therefore expected.
    nm-daemon = {
      url = "git+file:///home/laufan/Projects/nm-daemon?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    bt-daemon = {
      url = "git+file:///home/laufan/Projects/bt-daemon?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    shelllist = {
      url = "git+file:///home/laufan/Projects/shelllist?ref=main";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nm-daemon.follows = "nm-daemon";
        bt-daemon.follows = "bt-daemon";
      };
    };

    scratchpad = {
      url = "git+file:///home/laufan/Projects/scratchpad?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ts-react-quality-lens = {
      url = "git+file:///home/laufan/Projects/ts-react-quality-lens?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      };
      inherit (machine) system;
      pkgs = nixpkgs.legacyPackages.${system};
      unstablePkgs = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      connectParityProbe = inputs.nm-daemon.packages.${system}.connectParityProbe;
      homeManagerModule = {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          extraSpecialArgs = {
            inherit inputs machine unstablePkgs;
          };
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
          shellcheck -s bash -x -e SC1091 ${self}/config/scripts/*.sh
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
        specialArgs = {
          inherit inputs machine unstablePkgs;
        };
        modules = [
          ./configuration.nix
          inputs.sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          homeManagerModule
        ];
      };
    };
}
