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
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-desktop = {
      url = "github:Reginleif88/claude-cowork-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Declarative Flatpak management (pinned; see README for the convergent model)
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.7.0";

    # Image builders (EC2 AMI etc.) for the KiroCrew NixOS system.
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, nixpkgs-stable, home-manager, flake-utils, nixgl, claude-desktop, nix-flatpak, nixos-generators, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Single builder for every Home Manager profile. All profiles share the
      # one CLI-only ./home.nix and differ only by system, username, home dir,
      # and any extra modules (e.g. the COSMIC overlay).
      mkHome =
        { system
        , username ? "orre"
        , homeDirectory ? null
        , extraModules ? [ ]
        }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            pkgs-stable = nixpkgs-stable.legacyPackages.${system};
            inherit claude-desktop;
          } // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            nixgl = nixgl.packages.${system};
          };
          modules = [
            ./home.nix
            {
              home.username = username;
              home.homeDirectory =
                if homeDirectory != null then homeDirectory
                else if pkgs.stdenv.isDarwin then "/Users/${username}"
                else "/home/${username}";
            }
          ] ++ extraModules;
        };
    in
    {
      # Export overlays for reuse in other flakes
      overlays = {
        default = import ./overlays/nodejs.nix;
        nodejs = import ./overlays/nodejs.nix;
      };

      # Export custom libraries
      lib = { };

      # Export Home Manager modules for reuse
      homeModules = {
        default = ./home.nix;
        kiro = ./packages/kiro.nix;
      };

      # NixOS modules (reusable)
      nixosModules = {
        kirocrew = ./nixos/kirocrew.nix;
      };

      # Home Manager configurations (all generated from ./home.nix via mkHome)
      homeConfigurations = {
        # Fedora Silverblue daily driver (GNOME provided by the OS; home-manager is CLI-only)
        "orre" = mkHome {
          system = "x86_64-linux";
          extraModules = [
            nix-flatpak.homeManagerModules.nix-flatpak
            ./flatpak.nix
            ./packages/kiro.nix
          ];
        };

        # ARM Linux (EC2 Graviton / ARM workstation)
        "orre@aarch64" = mkHome { system = "aarch64-linux"; };

        # macOS (Apple Silicon)
        "orre@darwin" = mkHome { system = "aarch64-darwin"; };

        # Cosmic Atomic (ostree) VM = base + COSMIC desktop integration
        "orre@cosmic" = mkHome {
          system = "x86_64-linux";
          extraModules = [
            nix-flatpak.homeManagerModules.nix-flatpak
            ./flatpak.nix
            ./cosmic.nix
            ./packages/kiro.nix
          ];
        };

        # Devcontainers (VS Code / Codespaces; user is "vscode")
        "devcontainer" = mkHome {
          system = "x86_64-linux";
          username = "vscode";
          homeDirectory = "/home/vscode";
        };
        "devcontainer-arm" = mkHome {
          system = "aarch64-linux";
          username = "vscode";
          homeDirectory = "/home/vscode";
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

      # NixOS system configurations
      #   KiroCrew gateway VM: local QEMU now (`nixos-rebuild build-vm`), EC2 AMI later.
      #   Reuses this repo's ./home.nix with the same specialArgs as mkHome.
      nixosConfigurations.kirocrew = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nixos/kirocrew-host.nix
          ./nixos/kirocrew.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."x86_64-linux";
              inherit claude-desktop;
              nixgl = nixgl.packages."x86_64-linux";
            };
            home-manager.users.orre = { ... }: {
              imports = [ ./home.nix ];
            };
          }
        ];
      };

      # Live-managed EC2 box (aarch64 / Graviton). Launch the official NixOS AMI,
      # then drive it declaratively:
      #   nixos-rebuild switch --flake .#kirocrew-ec2 \
      #     --target-host root@<ip> --build-host root@<ip>
      # The box builds itself (no cross-compile, no heavy local build, no AMI
      # import), and reuses this repo's ./home.nix for the operator user.
      nixosConfigurations.kirocrew-ec2 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ./nixos/kirocrew-ec2.nix
          ./nixos/kirocrew.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."aarch64-linux";
              inherit claude-desktop;
            };
            home-manager.users.orre = { ... }: {
              imports = [ ./home.nix ];
            };
          }
        ];
      };

      # EC2 AMI image built from the SAME container + home modules as the local
      # VM (nixos-generators, amazon format). Swaps kirocrew-host.nix (QEMU) for
      # kirocrew-ec2.nix (key-only SSH; amazon profile supplies boot/rootfs).
      #   Build:  nix build .#packages.x86_64-linux.kirocrew-ami
      #   Then upload + register — see nixos/kirocrew.md.
      packages.x86_64-linux.kirocrew-ami = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        format = "amazon";
        modules = [
          ./nixos/kirocrew-ec2.nix
          ./nixos/kirocrew.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."x86_64-linux";
              inherit claude-desktop;
              nixgl = nixgl.packages."x86_64-linux";
            };
            home-manager.users.orre = { ... }: {
              imports = [ ./home.nix ];
            };
          }
        ];
      };

      # Legacy example retained for reference:
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