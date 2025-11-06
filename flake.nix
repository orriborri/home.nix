{
  description = "Home Manager and NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      powerlineLib = import ./lib/powerline.nix { inherit (pkgs) lib; };
      
    in {
      # Standalone Home Manager (for Fedora/non-NixOS)
      homeConfigurations."orre" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          { _module.args = { inherit powerlineLib; }; }
        ];
      };

      # NixOS system configurations
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.orre = import ./home.nix;
            home-manager.extraSpecialArgs = { inherit powerlineLib; };
          }
        ];
      };
    };
}