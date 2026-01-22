{
  description = "Home Manager and NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, nixpkgs-stable, home-manager, flake-utils, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Home Manager configurations
      homeConfigurations = {
        "orre" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          extraSpecialArgs = { 
            powerlineLib = import ./lib/powerline.nix { inherit (nixpkgs.legacyPackages.x86_64-linux) lib; };
            pkgs-stable = nixpkgs-stable.legacyPackages.x86_64-linux;
          };
          modules = [
            ./home.nix
          ];
        };
      };

      # Development shells for each system
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          buildInputs = with nixpkgs.legacyPackages.${system}; [
            nixfmt
            nil
            git
          ];
        };
      });

      # NixOS system configurations
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nixos/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.orre = { pkgs, lib, config, ... }: {
              imports = [ ./home.nix ];
            };
            home-manager.extraSpecialArgs = { 
              powerlineLib = import ./lib/powerline.nix { inherit (nixpkgs.legacyPackages.x86_64-linux) lib; };
              pkgs-stable = nixpkgs-stable.legacyPackages.x86_64-linux;
            };
          }
        ];
      };
    };
}