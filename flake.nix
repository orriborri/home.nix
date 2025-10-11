{
  description = "Home Manager configuration with waybar powerline helper";

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
      homeConfigurations."orre" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          {
            _module.args = { inherit powerlineLib; };
          }
        ];
      };
    };
}