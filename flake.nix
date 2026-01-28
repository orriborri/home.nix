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

  outputs = { self, nixpkgs, nixpkgs-stable, home-manager, flake-utils, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      
      # Helper to create powerlineLib for any system
      mkPowerlineLib = pkgs: import ./lib/powerline.nix { inherit (pkgs) lib; };
    in
    {
      # Export overlays for reuse in other flakes
      overlays = {
        default = import ./overlays/nodejs.nix;
        nodejs = import ./overlays/nodejs.nix;
      };

      # Export custom libraries
      lib = {
        powerline = import ./lib/powerline.nix;
      };

      # Export Home Manager modules for reuse
      homeModules = {
        default = ./home.nix;
        shell = ./modules/shell;
        development = ./modules/development;
        desktop = ./modules/desktop;
        utilities = ./modules/utilities.nix;
        security = ./modules/security.nix;
        kiro = ./packages/kiro.nix;
        sway = ./modules/wm/sway;
      };

      # Export NixOS modules
      nixosModules = {
        default = ./nixos/configuration.nix;
      };

      # Home Manager configurations
      homeConfigurations = {
        # Main configuration for user "orre"
        "orre" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          extraSpecialArgs = { 
            powerlineLib = mkPowerlineLib nixpkgs.legacyPackages.x86_64-linux;
            pkgs-stable = nixpkgs-stable.legacyPackages.x86_64-linux;
          };
          modules = [
            ./home.nix
          ];
        };

        # macOS configuration (if needed)
        "orre@darwin" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
          extraSpecialArgs = { 
            powerlineLib = mkPowerlineLib nixpkgs.legacyPackages.aarch64-darwin;
            pkgs-stable = nixpkgs-stable.legacyPackages.aarch64-darwin;
          };
          modules = [
            ./home.nix
          ];
        };

        # Minimal configuration without desktop environment
        "orre-minimal" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          extraSpecialArgs = { 
            powerlineLib = mkPowerlineLib nixpkgs.legacyPackages.x86_64-linux;
            pkgs-stable = nixpkgs-stable.legacyPackages.x86_64-linux;
          };
          modules = [
            ./home.nix
            { 
              # Override to disable desktop modules
              imports = nixpkgs.lib.mkForce [
                ./modules/shell
                ./modules/development
                ./modules/utilities.nix
                ./modules/security.nix
              ];
            }
          ];
        };
      };

      # Development shells for each system
      devShells = forAllSystems (system: 
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nixfmt
              nil
              git
            ];
            shellHook = ''
              echo "🚀 Nix development environment loaded"
              echo "Available commands:"
              echo "  - nixfmt: Format Nix files"
              echo "  - nil: Nix language server"
              echo ""
              echo "Quick commands:"
              echo "  - nix flake check: Validate flake"
              echo "  - nix fmt: Format all Nix files"
              echo "  - home-manager switch --flake .: Apply config"
            '';
          };
          
          # Additional shell for testing configurations
          test = pkgs.mkShell {
            buildInputs = with pkgs; [
              nixfmt
              nil
              git
              nix-tree
              nix-diff
            ];
          };
        }
      );

      # Formatter for 'nix fmt'
      formatter = forAllSystems (system: 
        nixpkgs.legacyPackages.${system}.nixfmt
      );

      # NixOS system configurations (example - requires proper hardware config)
      # Uncomment and customize for your system
      # nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      #   system = "x86_64-linux";
      #   modules = [
      #     ./nixos/configuration.nix
      #     home-manager.nixosModules.home-manager
      #     {
      #       home-manager.useGlobalPkgs = true;
      #       home-manager.useUserPackages = true;
      #       home-manager.users.orre = { pkgs, lib, config, ... }: {
      #         imports = [ ./home.nix ];
      #       };
      #       home-manager.extraSpecialArgs = { 
      #         powerlineLib = mkPowerlineLib nixpkgs.legacyPackages.x86_64-linux;
      #         pkgs-stable = nixpkgs-stable.legacyPackages.x86_64-linux;
      #       };
      #     }
      #   ];
      # };

      # Templates for bootstrapping new configs
      templates = {
        default = {
          path = ./templates/minimal;
          description = "Minimal Home Manager configuration with flakes";
        };
        minimal = {
          path = ./templates/minimal;
          description = "Minimal Home Manager configuration";
        };
      };

      # Apps for convenient commands
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${nixpkgs.legacyPackages.${system}.writeShellScript "home-manager-switch" ''
            ${home-manager.packages.${system}.default}/bin/home-manager switch --flake .
          ''}";
        };
        update = {
          type = "app";
          program = "${nixpkgs.legacyPackages.${system}.writeShellScript "update-flake" ''
            nix flake update
            ${home-manager.packages.${system}.default}/bin/home-manager switch --flake .
          ''}";
        };
      });
    };
}