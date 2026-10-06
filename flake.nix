{
  description = "Home Manager and NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Pinned rustc/cargo (1.91.1) for building pasta from source. nixos-24.11's
    # cargo (1.82) predates edition2024 (needed by datafusion et al.); current
    # nixos-unstable's rustc (1.98.1, built from a source tarball) mis-lowers
    # the avx512vnni vpdpwssd intrinsic and fails to compile lance-linalg
    # regardless of RUSTFLAGS. This revision is verified to build both.
    nixpkgs-rust.url = "github:NixOS/nixpkgs/f665af0cdb70ed27e1bd8f9fdfecaf451260fc55";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Official Claude Desktop Linux .deb, repackaged daily. No nixpkgs follows:
    # upstream only tests its own pin.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # Image builders (EC2 AMI etc.) for the KiroCrew NixOS system.
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management (age-encrypted, decrypted at activation)
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      nixpkgs-rust,
      home-manager,
      llm-agents,
      nixos-generators,
      sops-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Single builder for every Home Manager profile. All profiles share the
      # one CLI-only ./home.nix and differ only by system, username, home dir,
      # and any extra modules (e.g. the COSMIC overlay).
      mkHome =
        {
          system,
          username ? "orre",
          homeDirectory ? null,
          extraModules ? [ ],
        }:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            pkgs-stable = nixpkgs-stable.legacyPackages.${system};
            pkgs-rust = nixpkgs-rust.legacyPackages.${system};
            inherit llm-agents;
          };
          modules = [
            ./home.nix
            ./codex-policy.nix
            {
              home.username = username;
              home.homeDirectory =
                if homeDirectory != null then
                  homeDirectory
                else if pkgs.stdenv.hostPlatform.isDarwin then
                  "/Users/${username}"
                else
                  "/home/${username}";
            }
          ]
          ++ extraModules;
        };

      # Modules both workstation profiles (orre, orre@cosmic) load after their
      # own leading extras. Order matters to module merging, so each profile
      # keeps its prefix in front of this list.
      workstationModules = [
        ./kirocrew-service.nix
        ./kirocrew-agents-workstation.nix
        ./pasta-service.nix
        sops-nix.homeManagerModules.sops
        ./sops.nix
        {
          kirocrew.enable = true;
          kirocrew.role = "workstation";
          # Pin the daily source-update timer to the same release the
          # headless hosts run (./kirocrew-source-tag.nix).
          kirocrew.sourceTag = kirocrewSourceTag;
        }
      ];

      # Shared Home Manager module set for all KiroCrew NixOS outputs.
      # Imported by VM, EC2, and AMI — keeps them in sync so adding/removing
      # a KiroCrew module means editing one place.
      kirocrewModules = [
        ./home.nix
        ./packages/kiro.nix
        ./kirocrew-config.nix
        ./kirocrew-service.nix
        ./pasta-service.nix
        sops-nix.homeManagerModules.sops
        ./sops.nix
        # These outputs run home-manager under NixOS, not on a generic distro.
        { targets.genericLinux.enable = false; }
      ];

      # Pinned KiroCrew release, shared by the workstation and headless outputs
      # so every host builds the same immutable tag. Bump the one file to
      # upgrade. See ./kirocrew-source-tag.nix for the rationale.
      kirocrewSourceTag = import ./kirocrew-source-tag.nix;
    in
    {
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
            ./packages/kiro.nix
            ./packages/aws-vpn-client
            ./packages/claude-desktop.nix
          ]
          ++ workstationModules;
        };

        # ARM Linux (EC2 Graviton / ARM workstation)
        "orre@aarch64" = mkHome { system = "aarch64-linux"; };

        # macOS (Apple Silicon)
        "orre@darwin" = mkHome { system = "aarch64-darwin"; };

        # Cosmic Atomic (ostree) VM = base + COSMIC desktop integration
        "orre@cosmic" = mkHome {
          system = "x86_64-linux";
          extraModules = [
            ./cosmic.nix
            ./packages/kiro.nix
          ]
          ++ workstationModules;
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
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
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
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      # Pre-deploy gate: `nix flake check`, also run by .githooks/pre-push.
      # x86_64-linux only, the one system with a local builder; the other
      # systems' configurations are evaluated, not built, so they need none.
      checks.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit (nixpkgs) lib;

          # Force full evaluation of a configuration without building it:
          # discarding the string context leaves no build dependency.
          evalCheck =
            name: drvPath: pkgs.writeText "eval-${name}" (builtins.unsafeDiscardStringContext drvPath);

          # kirocrew-ec2 is aarch64 and nothing here can build for it, so
          # re-target it to x86_64 only to build the sops-nix checked manifest,
          # which fails when a secret names a key missing from secrets.yaml.
          ec2OnX86 = self.nixosConfigurations.kirocrew-ec2.extendModules {
            modules = [ { nixpkgs.hostPlatform = lib.mkForce "x86_64-linux"; } ];
          };
        in
        lib.mapAttrs' (
          name: hm: lib.nameValuePair "home-${name}" (evalCheck name hm.activationPackage.drvPath)
        ) self.homeConfigurations
        // lib.mapAttrs' (
          name: os: lib.nameValuePair "nixos-${name}" (evalCheck name os.config.system.build.toplevel.drvPath)
        ) self.nixosConfigurations
        // {
          kirocrew-ec2-sops = pkgs.writeText "kirocrew-ec2-sops" ec2OnX86.config.system.activationScripts.setupSecrets.text;

          # T9: tracked junk stays out of the repo, and caches and logs stay
          # ignored in every clone, not only where a global ignore covers them.
          repo-hygiene = pkgs.runCommand "check-repo-hygiene" { } ''
            cd ${self}
            fail=0
            for p in \
              nixos/users_approved.tsv \
              nixos/old-field-map-redshift.json \
              nixos/old-table-map-redshift.json \
              nixos/global-bundle.pem \
              'activate-window-by-title@lucaswerkmeister.de' \
              .claude/settings.local.json; do
              if [ -e "$p" ] || [ -L "$p" ]; then
                echo "tracked junk: $p" >&2
                fail=1
              fi
            done
            for pat in .pytest_cache/ .ruff_cache/ '*.log' logs/ .code-review-graph/ 'nixos/~/'; do
              if ! grep -qxF "$pat" .gitignore; then
                echo ".gitignore lacks: $pat" >&2
                fail=1
              fi
            done
            [ "$fail" = 0 ]
            touch $out
          '';

          # T3: every root input is used by something in this flake.
          no-dead-inputs = pkgs.runCommand "check-no-dead-inputs" { nativeBuildInputs = [ pkgs.jq ]; } ''
            dead=$(jq -r '.nodes.root.inputs | keys[] | select(. == "nixgl" or . == "flake-utils")' ${self}/flake.lock)
            if [ -n "$dead" ]; then
              echo "dead flake inputs: $dead" >&2
              exit 1
            fi
            touch $out
          '';

          # T7: the nodejs overlay had no consumer; keep it and its docs gone.
          no-unused-overlay = pkgs.runCommand "check-no-unused-overlay" { } ''
            cd ${self}
            fail=0
            if [ -e overlays/nodejs.nix ]; then
              echo "overlays/nodejs.nix still exists" >&2
              fail=1
            fi
            if grep -n 'home-nix\.overlays\|overlays/nodejs' README.md FLAKES.md AGENTS.md >&2; then
              fail=1
            fi
            [ "$fail" = 0 ]
            touch $out
          '';

          # S7: the workstation gateway runs with agent.sandbox off, so its
          # dashboard must only listen on loopback.
          kirocrew-gateway-loopback =
            let
              env = self.homeConfigurations.orre.config.systemd.user.services.kirocrew.Service.Environment;
            in
            pkgs.runCommand "check-kirocrew-gateway-loopback"
              {
                rendered = lib.concatStringsSep "\n" env;
                passAsFile = [ "rendered" ];
              }
              ''
                grep -qx 'KIROCREW_BIND=127.0.0.1' "$renderedPath" || {
                  echo "kirocrew.service must set KIROCREW_BIND=127.0.0.1; got:" >&2
                  grep KIROCREW_BIND "$renderedPath" >&2 || echo "(unset)" >&2
                  exit 1
                }
                touch $out
              '';

          # S10: the pinned KiroCrew tag is also pinned to a commit, and the
          # builder refuses a tag that no longer points at it.
          kirocrew-source-pin =
            let
              updater = pkgs.callPackage ./kirocrew-source-build.nix { } {
                pinnedSourceTag = import ./kirocrew-source-tag.nix;
              };
            in
            pkgs.runCommand "check-kirocrew-source-pin" { } ''
              script=${updater}/bin/kirocrew-source-update
              grep -q 'c67c5060a82faf6e5e1bc06077122c473d4ca456' "$script" \
                || { echo "updater does not embed the pinned commit" >&2; exit 1; }
              grep -q 'does not match pinned commit' "$script" \
                || { echo "updater does not verify the tag against the pinned commit" >&2; exit 1; }
              grep -q 'is at .*not pinned commit' "$script" \
                || { echo "updater does not verify an existing release dir against the pinned commit" >&2; exit 1; }
              touch $out
            '';

          # S11: the OpenVPN AWS patch is vendored, not fetched from a moving
          # branch URL.
          aws-vpn-patch-vendored = pkgs.runCommand "check-aws-vpn-patch-vendored" { } ''
            cd ${self}/packages/aws-vpn-client
            [ -s openvpn-v2.5.1-aws.patch ] \
              || { echo "openvpn-v2.5.1-aws.patch is not vendored" >&2; exit 1; }
            if grep -n 'raw.githubusercontent.com\|fetchpatch' default.nix >&2; then
              echo "default.nix still fetches the patch from a URL" >&2
              exit 1
            fi
            touch $out
          '';

          # C7: with kirocrew.enable = false no gateway unit is installed, even
          # on the workstation role.
          kirocrew-gateway-gated =
            let
              disabled = self.homeConfigurations.orre.extendModules {
                modules = [ { kirocrew.enable = lib.mkForce false; } ];
              };
            in
            pkgs.runCommand "check-kirocrew-gateway-gated"
              {
                installed = lib.boolToString (disabled.config.systemd.user.services ? kirocrew);
              }
              ''
                [ "$installed" = false ] || {
                  echo "kirocrew.service is installed although kirocrew.enable = false" >&2
                  exit 1
                }
                touch $out
              '';

          # D12: the gateway unit builds nothing, so it keeps systemd's default
          # start timeout (the 20 min override belongs to the source updater).
          kirocrew-gateway-default-timeout =
            let
              service = self.homeConfigurations.orre.config.systemd.user.services.kirocrew.Service;
            in
            pkgs.runCommand "check-kirocrew-gateway-default-timeout"
              {
                hasTimeout = lib.boolToString (service ? TimeoutStartSec);
              }
              ''
                [ "$hasTimeout" = false ] || {
                  echo "kirocrew.service overrides TimeoutStartSec; only the source updater builds" >&2
                  exit 1
                }
                if grep -n 'first source install' ${self}/kirocrew-service.nix >&2; then
                  echo "stale source-install comment in kirocrew-service.nix" >&2
                  exit 1
                fi
                touch $out
              '';

          # S4: the headless pasta build is pinned to a commit, not origin HEAD.
          pasta-pinned = pkgs.runCommand "check-pasta-pinned" { } ''
            f=${self}/nixos/kirocrew-services.nix
            if grep -n 'srcRoot.*origin HEAD' "$f" >&2; then
              echo "pasta build still follows origin HEAD" >&2
              exit 1
            fi
            grep -q 'pastaRev = "[0-9a-f]\{40\}"' "$f" \
              || { echo "no 40-hex pastaRev pinned in kirocrew-services.nix" >&2; exit 1; }
            touch $out
          '';

          # S4: the global npm agent backends install exact versions.
          acp-backends-pinned = pkgs.runCommand "check-acp-backends-pinned" { } ''
            f=${self}/nixos/kirocrew-services.nix
            for v in claudeAcpVersion codexAcpVersion; do
              grep -q "$v = \"[0-9]\+\.[0-9]\+\.[0-9]\+\"" "$f" \
                || { echo "$v is not pinned to x.y.z in kirocrew-services.nix" >&2; exit 1; }
            done
            if grep -n 'npm install --global @agentclientprotocol/[a-z-]*$' "$f" >&2; then
              echo "unversioned global npm install" >&2
              exit 1
            fi
            touch $out
          '';

          # C11/S4: code-review-graph's version lives in one file, and the EC2
          # install also freezes its dependencies to a cutoff date.
          crg-pinned = pkgs.runCommand "check-crg-pinned" { } ''
            cd ${self}
            [ -s crg-version.nix ] || { echo "crg-version.nix is missing" >&2; exit 1; }
            grep -q 'crg-version.nix' nixos/kirocrew-code.nix \
              || { echo "kirocrew-code.nix does not import crg-version.nix" >&2; exit 1; }
            if grep -n 'crgVersion = "' nixos/kirocrew-code.nix >&2; then
              echo "kirocrew-code.nix still hardcodes the version" >&2
              exit 1
            fi
            grep -q 'uv tool install --force --exclude-newer' nixos/kirocrew-code.nix \
              || { echo "uv tool install has no --exclude-newer" >&2; exit 1; }
            touch $out
          '';

          # S4: the MCP server venvs resolve dependencies as of a fixed date.
          mcp-venv-deps-frozen = pkgs.runCommand "check-mcp-venv-deps-frozen" { } ''
            f=${self}/nixos/kirocrew-services.nix
            n=$(grep -c 'pip" install .*mcp<2' "$f" || true)
            [ "$n" = 2 ] || { echo "expected 2 dependency installs, found $n" >&2; exit 1; }
            if grep -n 'pip" install .*mcp<2' "$f" | grep -v 'uploaded-prior-to' >&2; then
              echo "dependency install without --uploaded-prior-to" >&2
              exit 1
            fi
            touch $out
          '';

          # C11: the workstation installs the same pinned code-review-graph, only
          # when the installed version differs, and does not hide failures.
          crg-activation-pinned =
            let
              script = self.homeConfigurations.orre.config.home.activation.uvTools.data;
            in
            pkgs.runCommand "check-crg-activation-pinned"
              {
                inherit script;
                passAsFile = [ "script" ];
              }
              ''
                grep -q 'code-review-graph==2.3.8' "$scriptPath" \
                  || { echo "uvTools does not install code-review-graph==2.3.8" >&2; exit 1; }
                if grep -n '2>/dev/null || true' "$scriptPath" >&2; then
                  echo "uvTools still hides install failures" >&2
                  exit 1
                fi
                touch $out
              '';

          # C8: DOCKER_HOST follows the user's runtime dir instead of uid 1000.
          docker-host-uid-agnostic =
            let
              inherit (self.homeConfigurations.orre.config.home.sessionVariables) DOCKER_HOST;
            in
            pkgs.runCommand "check-docker-host-uid-agnostic" { inherit DOCKER_HOST; } ''
              case "$DOCKER_HOST" in
                *'/run/user/'[0-9]*) echo "DOCKER_HOST hardcodes a uid: $DOCKER_HOST" >&2; exit 1 ;;
                *'$XDG_RUNTIME_DIR/podman/podman.sock') ;;
                *) echo "unexpected DOCKER_HOST: $DOCKER_HOST" >&2; exit 1 ;;
              esac
              touch $out
            '';

          format = pkgs.runCommand "check-format" { nativeBuildInputs = [ self.formatter.x86_64-linux ]; } ''
            cd ${self}
            nixfmt --check $(find . -name '*.nix')
            touch $out
          '';
        };

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
              inherit llm-agents;
            };
            home-manager.users.orre = { ... }: {
              imports = kirocrewModules;
              kirocrew.enable = true;
              kirocrew.role = "headless";
              # Pinned to an immutable release tag (single source of truth:
              # ./kirocrew-source-tag.nix) so a new upstream release cannot
              # deploy itself unreviewed. Set to null to follow newest stable.
              kirocrew.sourceTag = kirocrewSourceTag;
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
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."aarch64-linux";
              inherit llm-agents;
            };
            home-manager.users.orre = { ... }: {
              imports = kirocrewModules;
              kirocrew.enable = true;
              kirocrew.role = "headless";
              # Pinned to an immutable release tag (single source of truth:
              # ./kirocrew-source-tag.nix) so a new upstream release cannot
              # deploy itself unreviewed. Set to null to follow newest stable.
              kirocrew.sourceTag = kirocrewSourceTag;
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
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."x86_64-linux";
              inherit llm-agents;
            };
            home-manager.users.orre = { ... }: {
              imports = kirocrewModules;
              kirocrew.enable = true;
              kirocrew.role = "headless";
              # Pinned to an immutable release tag (single source of truth:
              # ./kirocrew-source-tag.nix) so a new upstream release cannot
              # deploy itself unreviewed. Set to null to follow newest stable.
              kirocrew.sourceTag = kirocrewSourceTag;
            };
          }
        ];
      };

      # EC2 AMI for Graviton (aarch64). This is the target for the secure workspace.
      #   Build:  nix build .#packages.aarch64-linux.kirocrew-ami
      #   Requires an aarch64 builder (native or remote).
      packages.aarch64-linux.kirocrew-ami = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        format = "amazon";
        modules = [
          ./nixos/kirocrew-ec2.nix
          ./nixos/kirocrew.nix
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              pkgs-stable = nixpkgs-stable.legacyPackages."aarch64-linux";
              inherit llm-agents;
            };
            home-manager.users.orre = { ... }: {
              imports = kirocrewModules;
              kirocrew.enable = true;
              kirocrew.role = "headless";
              # Pinned to an immutable release tag (single source of truth:
              # ./kirocrew-source-tag.nix) so a new upstream release cannot
              # deploy itself unreviewed. Set to null to follow newest stable.
              kirocrew.sourceTag = kirocrewSourceTag;
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
