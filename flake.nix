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
        # O5: the HM sops-nix module validates secret keys in the manifest's
        # build-time checkPhase, which the context-stripped eval checks never
        # reach. Keeping the ExecStart string context pulls the sops-nix-user
        # script, and with it the checked manifest, into the build.
        // lib.mapAttrs' (
          name: hm:
          lib.nameValuePair "hm-sops-${name}" (
            pkgs.writeText "hm-sops-${name}" (
              toString hm.config.systemd.user.services.sops-nix.Service.ExecStart
            )
          )
        ) (lib.filterAttrs (_: hm: hm.config.systemd.user.services ? sops-nix) self.homeConfigurations)
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

          # O6: when `git fetch` fails the timer run exits non-zero even though a
          # release is installed, so a stuck tag discovery shows up as a failed
          # unit instead of silently succeeding every day.
          kirocrew-updater-fetch-failure =
            let
              updater = pkgs.callPackage ./kirocrew-source-build.nix { } { };
            in
            pkgs.runCommand "check-kirocrew-updater-fetch-failure"
              {
                nativeBuildInputs = [ pkgs.git ];
              }
              ''
                export HOME=$TMPDIR/home
                root=$HOME/.local/share/kirocrew-source
                mkdir -p "$root/current/.venv/bin" "$HOME/.local/bin"
                printf '#!/bin/sh\n' > "$root/current/.venv/bin/kirocrew"
                chmod +x "$root/current/.venv/bin/kirocrew"
                git init -q "$root/repository"
                git -C "$root/repository" remote add origin "$TMPDIR/does-not-exist"
                if ${updater}/bin/kirocrew-source-update --restart 2> "$TMPDIR/err"; then
                  echo "timer run exited 0 although git fetch failed" >&2
                  exit 1
                fi
                # ExecStartPre run (no argument): a transient fetch failure must
                # not keep the gateway from starting.
                ${updater}/bin/kirocrew-source-update 2> /dev/null \
                  || { echo "start-time run failed on a fetch error with a release installed" >&2; exit 1; }
                grep -q 'could not refresh KiroCrew tags' "$TMPDIR/err" \
                  || { echo "no fetch-failure message; got:" >&2; cat "$TMPDIR/err" >&2; exit 1; }
                touch $out
              '';

          # C10: one neovim module. No second config file, no plugin declared
          # twice, which-key set up once.
          nvim-single-module =
            let
              nv = self.homeConfigurations.orre.config.programs.neovim;
            in
            pkgs.runCommand "check-nvim-single-module"
              {
                plugins = lib.concatMapStringsSep "\n" (p: (p.plugin or p).name) nv.plugins;
                inherit (nv) initLua;
                passAsFile = [
                  "plugins"
                  "initLua"
                ];
              }
              ''
                [ ! -e ${self}/neovim-config.nix ] \
                  || { echo "neovim-config.nix still exists next to neovim.nix" >&2; exit 1; }
                dups=$(sort "$pluginsPath" | uniq -d)
                [ -z "$dups" ] || { echo "plugins declared twice: $dups" >&2; exit 1; }
                n=$(grep -c 'which-key").setup\|wk.setup' "$initLuaPath" || true)
                [ "$n" -le 1 ] || { echo "which-key set up $n times" >&2; exit 1; }
                touch $out
              '';

          # C10: g:clipboard is forced to wl-copy only under Wayland; darwin, X11
          # and ssh sessions keep neovim's own provider detection.
          nvim-clipboard-wayland-only =
            let
              gen = self.homeConfigurations.orre.activationPackage;
              nvim = self.homeConfigurations.orre.config.programs.neovim.finalPackage;
            in
            pkgs.runCommand "check-nvim-clipboard-wayland-only" { } ''
              export HOME=$TMPDIR
              export XDG_CONFIG_HOME=${gen}/home-files/.config
              export XDG_DATA_HOME=${gen}/home-files/.local/share
              probe() {
                ${nvim}/bin/nvim --headless \
                  +'lua io.stdout:write(vim.g.clipboard and "set" or "unset", "\n")' +q 2> /dev/null
              }
              unset WAYLAND_DISPLAY
              [ "$(probe)" = unset ] \
                || { echo "g:clipboard is forced without WAYLAND_DISPLAY" >&2; exit 1; }
              [ "$(WAYLAND_DISPLAY=wayland-0 probe)" = set ] \
                || { echo "g:clipboard is not set under WAYLAND_DISPLAY" >&2; exit 1; }
              touch $out
            '';

          # D10: the diagnostic maps call nothing neovim 0.12 deprecates.
          nvim-no-deprecated-diagnostic-maps =
            let
              gen = self.homeConfigurations.orre.activationPackage;
              nvim = self.homeConfigurations.orre.config.programs.neovim.finalPackage;
            in
            pkgs.runCommand "check-nvim-no-deprecated-diagnostic-maps" { } ''
              export HOME=$TMPDIR
              export XDG_CONFIG_HOME=${gen}/home-files/.config
              export XDG_DATA_HOME=${gen}/home-files/.local/share
              got=$(${nvim}/bin/nvim --headless \
                +'lua for _, lhs in ipairs({ "[d", "]d" }) do vim.fn.maparg(lhs, "n", false, true).callback() end' \
                +'lua io.stdout:write(vim.fn.execute("messages"), "\n")' +q 2> /dev/null)
              case "$got" in
                *deprecated*) echo "diagnostic map calls a deprecated function: $got" >&2; exit 1 ;;
              esac
              touch $out
            '';

          # C33: which-key add() entries with a rhs are descriptions only; the
          # fugitive leader maps must be real keymaps.
          nvim-fugitive-maps-bound =
            let
              gen = self.homeConfigurations.orre.activationPackage;
              nvim = self.homeConfigurations.orre.config.programs.neovim.finalPackage;
            in
            pkgs.runCommand "check-nvim-fugitive-maps-bound" { } ''
              export HOME=$TMPDIR
              export XDG_CONFIG_HOME=${gen}/home-files/.config
              export XDG_DATA_HOME=${gen}/home-files/.local/share
              ${nvim}/bin/nvim --headless \
                +'lua for _, lhs in ipairs({ " gs", " gc", " gl", " gd" }) do if vim.fn.maparg(lhs, "n") == "" then io.stderr:write("unbound leader map: ", lhs, "\n") vim.cmd("cquit 1") end end' \
                +q
              touch $out
            '';

          # T16: every formatter in extraPackages is wired into conform; the repo
          # formats nix with nixfmt, not nixpkgs-fmt.
          nvim-no-unwired-formatters =
            pkgs.runCommand "check-nvim-no-unwired-formatters"
              {
                extraPackages =
                  lib.concatMapStringsSep "\n" lib.getName
                    self.homeConfigurations.orre.config.programs.neovim.extraPackages;
                passAsFile = [ "extraPackages" ];
              }
              ''
                if grep -nx 'prettier\|stylua\|nixpkgs-fmt' "$extraPackagesPath" >&2; then
                  echo "formatter installed but not wired into conform" >&2
                  exit 1
                fi
                touch $out
              '';

          # O7: language servers come from extraPackages; mason would download
          # dynamically linked copies that shadow them and fail on NixOS.
          nvim-no-mason =
            let
              nv = self.homeConfigurations.orre.config.programs.neovim;
            in
            pkgs.runCommand "check-nvim-no-mason"
              {
                plugins = lib.concatMapStringsSep "\n" (p: (p.plugin or p).name) nv.plugins;
                inherit (nv) initLua;
                passAsFile = [
                  "plugins"
                  "initLua"
                ];
              }
              ''
                if grep -n mason "$pluginsPath" "$initLuaPath" >&2; then
                  echo "mason is still installed or set up" >&2
                  exit 1
                fi
                touch $out
              '';

          # C25: the packaged nvim-treesitter is the main branch, whose setup()
          # ignores highlight/indent; highlighting must be started per buffer.
          nvim-treesitter-active =
            let
              gen = self.homeConfigurations.orre.activationPackage;
              nvim = self.homeConfigurations.orre.config.programs.neovim.finalPackage;
            in
            pkgs.runCommand "check-nvim-treesitter-active" { } ''
              export HOME=$TMPDIR
              export XDG_CONFIG_HOME=${gen}/home-files/.config
              export XDG_DATA_HOME=${gen}/home-files/.local/share
              printf 'def f():\n    return 1\n' > "$TMPDIR/x.py"
              got=$(${nvim}/bin/nvim --headless "$TMPDIR/x.py" \
                +'lua io.stdout:write(tostring(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil), " ", vim.bo.indentexpr, "\n")' \
                +q 2> /dev/null)
              case "$got" in
                "true v:lua.require'nvim-treesitter'.indentexpr()") ;;
                *) echo "treesitter not active on a python buffer: got '$got'" >&2; exit 1 ;;
              esac
              touch $out
            '';

          # C29: python buffers get no 2-space setlocal or retab-on-save; conform's
          # ruff_format owns python indentation and the two fought on every save.
          nvim-no-python-retab =
            pkgs.runCommand "check-nvim-no-python-retab"
              {
                cfg = self.homeConfigurations.orre.config.programs.neovim.extraConfig;
                passAsFile = [ "cfg" ];
              }
              ''
                if grep -n 'retab\|FileType python setlocal' "$cfgPath" >&2; then
                  echo "python retab autocmd still in the rendered neovim config" >&2
                  exit 1
                fi
                touch $out
              '';

          # S11: the OpenVPN AWS patch is vendored, not fetched from a moving
          # branch URL, and tracks the 2.6 series nixpkgs ships.
          aws-vpn-patch-vendored = pkgs.runCommand "check-aws-vpn-patch-vendored" { } ''
            cd ${self}/packages/aws-vpn-client
            [ -s openvpn-v2.6.12-aws.patch ] \
              || { echo "openvpn-v2.6.12-aws.patch is not vendored" >&2; exit 1; }
            if grep -n 'openvpn-2\.5\|2\.5\.1-aws' default.nix >&2; then
              echo "default.nix still pins OpenVPN 2.5.1" >&2
              exit 1
            fi
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

          # C8: the git SSH identity path on the headless hosts uses ssh's %i
          # (local uid) token, not the EC2 uid. Evaluates the aarch64 config's
          # rendered text only; nothing is built for aarch64.
          ssh-identity-uid-agnostic =
            let
              sshConfig =
                pkgs.writeText "ec2-ssh-config"
                  self.nixosConfigurations.kirocrew-ec2.config.home-manager.users.orre.home.file.".ssh/config".text;
            in
            pkgs.runCommand "check-ssh-identity-uid-agnostic" { } ''
              if grep -n '/run/user/[0-9]' ${sshConfig} >&2; then
                echo "ssh config hardcodes a uid in /run/user" >&2
                exit 1
              fi
              grep -q 'IdentityFile /run/user/%i/secrets/git-ssh-key' ${sshConfig} \
                || { echo "git identity does not use /run/user/%i" >&2; exit 1; }
              touch $out
            '';

          # C19: systemd does not expand %r, so pasta.service must read its
          # secrets from the %t (runtime dir) path sops-nix writes to.
          pasta-env-file-specifier =
            let
              envFile = self.homeConfigurations.orre.config.systemd.user.services.pasta.Service.EnvironmentFile;
            in
            pkgs.runCommand "check-pasta-env-file-specifier" { inherit envFile; } ''
              [ "$envFile" = "-%t/secrets/pasta-fetchers.env" ] || {
                echo "pasta.service EnvironmentFile is '$envFile', want -%t/secrets/pasta-fetchers.env" >&2
                exit 1
              }
              touch $out
            '';

          # S14: no generated zsh file puts a cwd-relative directory on PATH.
          zsh-no-relative-path =
            let
              files = self.homeConfigurations.orre.config.home.file;
              zshText = lib.concatMapStringsSep "\n" (n: files.${n}.text) [
                ".zshenv"
                ".config/zsh/.zshenv"
                ".config/zsh/.zprofile"
                ".config/zsh/.zshrc"
              ];
            in
            pkgs.runCommand "check-zsh-no-relative-path"
              {
                inherit zshText;
                passAsFile = [ "zshText" ];
              }
              ''
                if grep -nE 'PATH="\./|PATH=\./|:\./[A-Za-z_]' "$zshTextPath" >&2; then
                  echo "a zsh file puts a cwd-relative directory on PATH" >&2
                  exit 1
                fi
                touch $out
              '';

          # C22: the one-off ~/ReadPeak migration (which could rmtree a real
          # directory on every switch) is gone.
          no-readpeak-migration =
            pkgs.runCommand "check-no-readpeak-migration"
              {
                present = lib.boolToString (
                  self.homeConfigurations.orre.config.home.activation ? migrateReadPeakPaths
                );
              }
              ''
                [ "$present" = false ] || {
                  echo "home.activation.migrateReadPeakPaths still exists" >&2
                  exit 1
                }
                touch $out
              '';

          # S15: the gateway can find the host's systemd-run, which it needs to
          # enforce agent cgroup limits.
          kirocrew-gateway-path-has-systemd-run =
            let
              env = self.homeConfigurations.orre.config.systemd.user.services.kirocrew.Service.Environment;
            in
            pkgs.runCommand "check-kirocrew-gateway-path-has-systemd-run"
              {
                rendered = lib.concatStringsSep "\n" env;
                passAsFile = [ "rendered" ];
              }
              ''
                path=$(grep '^PATH=' "$renderedPath" | head -1)
                case ":''${path#PATH=}:" in
                  *:/usr/bin:*) ;;
                  *) echo "gateway PATH lacks /usr/bin (systemd-run): $path" >&2; exit 1 ;;
                esac
                touch $out
              '';

          # C21: a failing clone or `crg register` during activation is reported,
          # not swallowed. Runs the real rendered scripts against a scratch HOME
          # with a broken remote and a failing code-review-graph.
          activation-reports-failures =
            let
              act = self.homeConfigurations.orre.config.home.activation;
            in
            pkgs.runCommand "check-activation-reports-failures"
              {
                clone = act.cloneRepos.data;
                register = act.crgRegisterRepos.data;
                passAsFile = [
                  "clone"
                  "register"
                ];
                nativeBuildInputs = [ pkgs.git ];
              }
              ''
                export HOME=$TMPDIR/home
                mkdir -p $HOME/.config/kirocrew $HOME/.local/bin $HOME/code/ok/.git
                cat > $HOME/.config/kirocrew/repos.toml <<'EOF'
                [[repos]]
                remote = "file:///nonexistent/broken.git"
                path = "code/broken/repo"

                [[repos]]
                remote = "file:///nonexistent/ok.git"
                path = "code/ok"
                EOF
                printf '#!/bin/sh\necho "crg exploded" >&2\nexit 3\n' > $HOME/.local/bin/code-review-graph
                chmod +x $HOME/.local/bin/code-review-graph

                bash "$clonePath" > clone.out 2> clone.err || true
                bash "$registerPath" > reg.out 2> reg.err || true
                cat clone.out clone.err reg.out reg.err

                grep -qi 'warning.*broken' clone.out clone.err \
                  || { echo "failed clone was not reported" >&2; exit 1; }
                grep -qi 'warning.*register\|crg exploded' reg.out reg.err \
                  || { echo "failed crg register was not reported" >&2; exit 1; }
                touch $out
              '';

          # C17: unit PATHs follow home.username instead of hardcoding orre.
          unit-path-follows-username =
            let
              other = self.homeConfigurations.orre.extendModules {
                modules = [ { home.username = lib.mkForce "someone"; } ];
              };
              svc = other.config.systemd.user.services;
              envText = lib.concatStringsSep "\n" (
                svc.kirocrew.Service.Environment ++ svc.pasta.Service.Environment
              );
            in
            pkgs.runCommand "check-unit-path-follows-username"
              {
                inherit envText;
                passAsFile = [ "envText" ];
              }
              ''
                if grep -n 'per-user/orre' "$envTextPath" >&2; then
                  echo "a unit PATH hardcodes per-user/orre" >&2
                  exit 1
                fi
                [ "$(grep -c 'per-user/someone/bin' "$envTextPath")" = 2 ] \
                  || { echo "both units should use per-user/<home.username>/bin" >&2; exit 1; }
                touch $out
              '';

          # C17: generated zsh files follow home.homeDirectory instead of
          # hardcoding /home/orre.
          zsh-follows-home-directory =
            let
              other = self.homeConfigurations.orre.extendModules {
                modules = [ { home.homeDirectory = lib.mkForce "/home/someone"; } ];
              };
              files = other.config.home.file;
              zshText = lib.concatMapStringsSep "\n" (n: files.${n}.text) [
                ".zshenv"
                ".config/zsh/.zshenv"
                ".config/zsh/.zprofile"
                ".config/zsh/.zshrc"
              ];
            in
            pkgs.runCommand "check-zsh-follows-home-directory"
              {
                inherit zshText;
                passAsFile = [ "zshText" ];
              }
              ''
                if grep -n '/home/orre' "$zshTextPath" >&2; then
                  echo "a zsh file hardcodes /home/orre" >&2
                  exit 1
                fi
                touch $out
              '';

          # C1: pasta-source-build takes a lock, so the daemon's pre-start and the
          # timer units (and manual runs) cannot build in the same checkout at
          # once. Builds the real script from the EC2 config retargeted to x86.
          pasta-build-locked =
            let
              pre = ec2OnX86.config.systemd.services.pasta-daemon.serviceConfig.ExecStartPre;
              script = if builtins.isList pre then builtins.head pre else pre;
            in
            pkgs.runCommand "check-pasta-build-locked" { inherit script; } ''
              f=$script
              grep -q 'flock 9' "$f" || { echo "pasta-source-build does not take a lock" >&2; exit 1; }
              grep -q '\.build\.lock' "$f" || { echo "no .build.lock file used" >&2; exit 1; }
              touch $out
            '';

          # S17: the workstation gateway has the same memory caps as the EC2 unit.
          kirocrew-gateway-memory-caps =
            let
              service = self.homeConfigurations.orre.config.systemd.user.services.kirocrew.Service;
            in
            pkgs.runCommand "check-kirocrew-gateway-memory-caps"
              {
                high = service.MemoryHigh or "unset";
                max = service.MemoryMax or "unset";
              }
              ''
                [ "$high" = 70% ] && [ "$max" = 85% ] || {
                  echo "kirocrew.service MemoryHigh=$high MemoryMax=$max, want 70% and 85%" >&2
                  exit 1
                }
                touch $out
              '';

          # T11: nothing patches the orphaned pipx kirocrew venv; the source
          # updater (kirocrew-source-build.nix) owns the tzdata pin.
          no-pipx-tzdata-activation =
            pkgs.runCommand "check-no-pipx-tzdata-activation"
              {
                present = lib.boolToString (self.homeConfigurations.orre.config.home.activation ? kirocrewTzdata);
              }
              ''
                [ "$present" = false ] || {
                  echo "home.activation.kirocrewTzdata still exists" >&2
                  exit 1
                }
                touch $out
              '';

          # T14: variables already in home.sessionVariables are not repeated in
          # programs.zsh.sessionVariables (the zsh copy lands in .zshenv and would
          # silently win), and the effective values stay set.
          no-duplicate-session-vars =
            let
              cfg = self.homeConfigurations.orre.config;
              names = [
                "EDITOR"
                "VISUAL"
                "NPM_CONFIG_PREFIX"
                "FZF_DEFAULT_OPTS"
              ];
              dup = lib.filter (n: cfg.programs.zsh.sessionVariables ? ${n}) names;
              unset = lib.filter (n: !(cfg.home.sessionVariables ? ${n})) names;
            in
            pkgs.runCommand "check-no-duplicate-session-vars"
              {
                dup = lib.concatStringsSep " " dup;
                unset = lib.concatStringsSep " " unset;
              }
              ''
                [ -z "$dup" ] || { echo "repeated in programs.zsh.sessionVariables: $dup" >&2; exit 1; }
                [ -z "$unset" ] || { echo "missing from home.sessionVariables: $unset" >&2; exit 1; }
                touch $out
              '';

          # T15: zsh uses the vi insert keymap explicitly, and no variable
          # configures the zsh-vi-mode plugin (not installed).
          zsh-vi-keymap =
            let
              zsh = self.homeConfigurations.orre.config.programs.zsh;
            in
            pkgs.runCommand "check-zsh-vi-keymap"
              {
                keymap = if zsh.defaultKeymap == null then "unset" else zsh.defaultKeymap;
                zvm = lib.boolToString (zsh.sessionVariables ? ZVM_VI_INSERT_ESCAPE_BINDKEY);
              }
              ''
                [ "$keymap" = viins ] || { echo "programs.zsh.defaultKeymap is $keymap, want viins" >&2; exit 1; }
                [ "$zvm" = false ] || { echo "ZVM_VI_INSERT_ESCAPE_BINDKEY is set but zsh-vi-mode is not installed" >&2; exit 1; }
                touch $out
              '';

          # C6: crew registration runs the agent CLI through a shared helper that
          # bounds it with `timeout 60`, so a hung CLI cannot wedge the unit.
          # Builds on the EC2 config retargeted to x86.
          crew-registration-timeout =
            let
              unit = ec2OnX86.config.systemd.services.kirocrew-register-agents;
              execs = map toString (lib.toList unit.serviceConfig.ExecStart);
            in
            pkgs.runCommand "check-crew-registration-timeout"
              {
                execs = lib.concatStringsSep " " execs;
              }
              ''
                n=0
                for f in $execs; do
                  n=$((n + 1))
                  grep -q 'timeout 60' "$f" || {
                    echo "$f does not bound the CLI with timeout 60" >&2
                    exit 1
                  }
                done
                [ "$n" = 3 ] || { echo "expected 3 registration scripts, got $n" >&2; exit 1; }
                touch $out
              '';

          # C6: crews register once the gateway is up (the crew-venv symlink only
          # exists after its ExecStartPre), from one oneshot unit that runs the
          # three registration scripts; activation only writes the specs.
          crew-registration-service =
            let
              cfg = ec2OnX86.config;
              unit = cfg.systemd.services.kirocrew-register-agents or null;
              scripts = cfg.system.activationScripts;
            in
            pkgs.runCommand "check-crew-registration-service"
              {
                present = lib.boolToString (unit != null);
                after = lib.concatStringsSep " " (unit.after or [ ]);
                execs = toString (builtins.length (lib.toList (unit.serviceConfig.ExecStart or [ ])));
                activation = lib.concatStringsSep "\n" [
                  scripts.kirocrew-review-agents.text
                  scripts.kirocrew-dev-crew.text
                  scripts.kirocrew-assistant.text
                ];
                passAsFile = [ "activation" ];
              }
              ''
                [ "$present" = true ] || { echo "systemd.services.kirocrew-register-agents is missing" >&2; exit 1; }
                case " $after " in *" kirocrew-gateway.service "*) ;; *) echo "kirocrew-register-agents is not ordered after kirocrew-gateway.service ($after)" >&2; exit 1;; esac
                [ "$execs" = 3 ] || { echo "kirocrew-register-agents has $execs ExecStart entries, want 3" >&2; exit 1; }
                if grep -q 'agent create' "$activationPath"; then
                  echo "an activation script still registers crews" >&2
                  exit 1
                fi
                touch $out
              '';

          # O1: the EC2 journal is capped so logs cannot fill the fixed 79G root.
          ec2-journald-cap =
            let
              cap = ec2OnX86.config.services.journald.settings.Journal.SystemMaxUse or "unset";
            in
            pkgs.runCommand "check-ec2-journald-cap" { inherit cap; } ''
              [ "$cap" = 1G ] || { echo "journald SystemMaxUse is $cap, want 1G" >&2; exit 1; }
              touch $out
            '';

          # O1: the source updater prunes old release worktrees, keeping the
          # current and previous releases and recent `.stale-*` moves aside.
          kirocrew-prune-releases =
            let
              prune = import ./kirocrew-prune-releases.nix { inherit pkgs; };
            in
            pkgs.runCommand "check-kirocrew-prune-releases"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.coreutils
                ];
                inherit prune;
              }
              ''
                export HOME=$TMPDIR GIT_CONFIG_GLOBAL=/dev/null
                repo=$TMPDIR/repo
                rel=$TMPDIR/releases
                git init -q "$repo"
                git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
                mkdir -p "$rel/v1" "$rel/v2" "$rel/v3" "$rel/v0.stale-new" "$rel/v0.stale-old"
                touch -d '10 days ago' "$rel/v0.stale-old"
                "$prune/bin/kirocrew-prune-releases" "$rel" "$rel/v3" "$rel/v2" "$repo"
                got=$(ls "$rel" | tr '\n' ' ')
                want="v0.stale-new v2 v3 "
                [ "$got" = "$want" ] || { echo "kept: $got; want: $want" >&2; exit 1; }
                # no previous release, empty current: must not delete everything
                "$prune/bin/kirocrew-prune-releases" "$rel" "$rel/v3" "" "$repo"
                [ -d "$rel/v3" ] || { echo "current release was pruned" >&2; exit 1; }
                touch $out
              '';

          # O1: a daily timer fails when the EC2 root is more than 85% full, so
          # a filling disk shows up in `systemctl list-units --failed`.
          ec2-disk-check =
            let
              cfg = ec2OnX86.config;
              timer = cfg.systemd.timers.kirocrew-disk-check.timerConfig or null;
              exec = cfg.systemd.services.kirocrew-disk-check.serviceConfig.ExecStart or "";
            in
            pkgs.runCommand "check-ec2-disk-check"
              {
                calendar = if timer == null then "missing" else timer.OnCalendar or "unset";
                inherit exec;
              }
              ''
                [ "$calendar" = daily ] || { echo "kirocrew-disk-check timer OnCalendar is $calendar, want daily" >&2; exit 1; }
                set -- $exec
                bin=$1
                [ -x "$bin" ] || { echo "no disk-check executable in ExecStart: $exec" >&2; exit 1; }
                "$bin" "$TMPDIR" 100 || { echo "disk check failed below the threshold" >&2; exit 1; }
                if "$bin" "$TMPDIR" -1; then
                  echo "disk check passed although usage exceeds the threshold" >&2
                  exit 1
                fi
                touch $out
              '';

          # O4: the EC2 config does not re-declare /tmp; NixOS stage 2 already
          # runs `install -m 01777 -d /tmp` (stage-2-init.sh), so the rule is a
          # no-op.
          ec2-no-tmp-tmpfiles-rule =
            let
              rules = ec2OnX86.config.systemd.tmpfiles.rules;
              tmp = lib.filter (r: builtins.match "d /tmp .*" r != null) rules;
            in
            pkgs.runCommand "check-ec2-no-tmp-tmpfiles-rule" { tmp = lib.concatStringsSep "; " tmp; } ''
              [ -z "$tmp" ] || { echo "redundant /tmp tmpfiles rule: $tmp" >&2; exit 1; }
              touch $out
            '';

          # S12: the EC2 module does not carry an empty authorizedKeys stub
          # (access is SSM-only; keys would be added deliberately, not by a
          # placeholder comment).
          ec2-no-empty-authorized-keys =
            let
              text = builtins.readFile ./nixos/kirocrew-security.nix;
            in
            pkgs.runCommand "check-ec2-no-empty-authorized-keys"
              { present = lib.boolToString (lib.hasInfix "authorizedKeys" text); }
              ''
                [ "$present" = false ] || {
                  echo "nixos/kirocrew-security.nix still has an authorizedKeys stub" >&2
                  exit 1
                }
                touch $out
              '';

          # S12: the EC2 firewall opens no inbound TCP port. SSM's
          # AWS-StartSSHSession connects to sshd over loopback, which the NixOS
          # firewall always accepts, so port 22 need not be open.
          ec2-firewall-no-inbound-tcp =
            let
              ports = self.nixosConfigurations.kirocrew-ec2.config.networking.firewall.allowedTCPPorts;
            in
            pkgs.runCommand "check-ec2-firewall-no-inbound-tcp" { ports = toString ports; } ''
              [ -z "$ports" ] || { echo "EC2 firewall allows TCP ports: $ports" >&2; exit 1; }
              touch $out
            '';

          # O8: the headless EC2 home has no gpg-agent with a GUI pinentry; the
          # workstation keeps it.
          gpg-agent-headless =
            let
              ec2 = ec2OnX86.config.home-manager.users.orre.services.gpg-agent.enable;
              ws = self.homeConfigurations.orre.config.services.gpg-agent.enable;
            in
            pkgs.runCommand "check-gpg-agent-headless"
              {
                ec2 = lib.boolToString ec2;
                ws = lib.boolToString ws;
              }
              ''
                [ "$ec2" = false ] || { echo "gpg-agent is enabled on the headless EC2 home" >&2; exit 1; }
                [ "$ws" = true ] || { echo "gpg-agent is disabled on the workstation" >&2; exit 1; }
                touch $out
              '';

          # C23: the agent specs do not set env.KIROCREW_HOME on the @kirocrew-core
          # MCP entry (the gateway drops the reserved KIROCREW_ namespace), and
          # no caller passes a crewHome for it.
          agent-specs-no-kirocrew-home =
            let
              specs = builtins.readFile ./kirocrew-agent-specs.nix;
              callers = lib.concatMapStringsSep "\n" (f: builtins.readFile f) [
                ./kirocrew-agents-workstation.nix
                ./nixos/kirocrew-assistant.nix
                ./nixos/kirocrew-dev-crew.nix
                ./nixos/kirocrew-review-agents.nix
              ];
            in
            pkgs.runCommand "check-agent-specs-no-kirocrew-home"
              {
                inherit specs callers;
                passAsFile = [
                  "specs"
                  "callers"
                ];
              }
              ''
                if grep -n 'KIROCREW_HOME\|crewHome' "$specsPath" >&2; then
                  echo "kirocrew-agent-specs.nix still handles KIROCREW_HOME/crewHome" >&2
                  exit 1
                fi
                if grep -n 'inherit kirocrewBin crewHome' "$callersPath" >&2; then
                  echo "a caller still passes crewHome to the specs" >&2
                  exit 1
                fi
                touch $out
              '';

          # O10: the `nix flake check` gate also runs in CI (the pre-push hook is
          # per clone), and the workflow files lint clean.
          github-workflows =
            let
              dir = ./.github/workflows;
            in
            pkgs.runCommand "check-github-workflows"
              {
                nativeBuildInputs = [ pkgs.actionlint ];
                present = lib.boolToString (builtins.pathExists dir);
                src = if builtins.pathExists dir then dir else null;
              }
              ''
                [ "$present" = true ] || { echo ".github/workflows is missing" >&2; exit 1; }
                grep -rq 'nix flake check' "$src" || { echo "no workflow runs nix flake check" >&2; exit 1; }
                actionlint "$src"/*.yml
                touch $out
              '';

          # O11: one mechanism bumps nixpkgs-stable (update.sh bump_stable_channel);
          # renovate.json keeps only the nix manager and lockfile maintenance.
          renovate-single-bump-mechanism =
            let
              cfg = builtins.fromJSON (builtins.readFile ./renovate.json);
            in
            pkgs.runCommand "check-renovate-single-bump-mechanism"
              {
                regex = lib.boolToString (cfg ? regexManagers);
                nix = lib.boolToString (cfg.nix.enabled or false);
                lock = lib.boolToString (cfg.lockFileMaintenance.enabled or false);
              }
              ''
                [ "$regex" = false ] || { echo "renovate.json still has regexManagers" >&2; exit 1; }
                [ "$nix" = true ] && [ "$lock" = true ] || { echo "renovate.json lost the nix manager or lockFileMaintenance" >&2; exit 1; }
                touch $out
              '';

          # C26: update.sh reaches `home-manager switch` on a host without flatpak
          # (a failing `command -v` inside an assignment is fatal under set -e).
          # Runs the script against stub commands in a scratch dir.
          update-sh-no-flatpak =
            pkgs.runCommand "check-update-sh-no-flatpak"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                ];
              }
              ''
                mkdir -p "$TMPDIR/repo" "$TMPDIR/bin"
                cp ${./update.sh} "$TMPDIR/repo/update.sh"
                for c in home-manager nix-collect-garbage nix; do
                  printf '#!/bin/sh\necho "stub %s $*"\n' "$c" > "$TMPDIR/bin/$c"
                  chmod +x "$TMPDIR/bin/$c"
                done
                result=$(PATH="$TMPDIR/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.bash}/bin" \
                  bash "$TMPDIR/repo/update.sh" 2>&1) || { echo "update.sh failed without flatpak:" >&2; echo "$result" >&2; exit 1; }
                echo "$result" | grep -q 'stub home-manager switch' \
                  || { echo "update.sh did not reach home-manager switch:" >&2; echo "$result" >&2; exit 1; }
                touch $out
              '';

          # C27: the stable-channel bump ignores a nixos-YY.MM branch until its
          # YY.MM release tag exists (the branch appears as a beta weeks earlier).
          # Runs `update.sh --update` against stub git/date/nix in a scratch dir.
          update-sh-stable-channel-release =
            pkgs.runCommand "check-update-sh-stable-channel-release"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.gnused
                ];
              }
              ''
                mkdir -p "$TMPDIR/repo" "$TMPDIR/bin"
                cp ${./update.sh} "$TMPDIR/repo/update.sh"
                printf 'x = { nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11"; };\n' > "$TMPDIR/repo/flake.nix"
                cat > "$TMPDIR/bin/git" <<'EOS'
                #!/bin/sh
                case "$*" in
                  *--heads*) printf 'a\trefs/heads/nixos-25.11\na\trefs/heads/nixos-26.05\na\trefs/heads/nixos-26.11\n' ;;
                  *--tags*) printf 'a\trefs/tags/25.11\na\trefs/tags/26.05\na\trefs/tags/26.05-beta\na\trefs/tags/26.11-pre\n' ;;
                esac
                EOS
                printf '#!/bin/sh\necho 2611\n' > "$TMPDIR/bin/date"
                for c in nix home-manager nix-collect-garbage; do
                  printf '#!/bin/sh\n' > "$TMPDIR/bin/$c"
                done
                chmod +x "$TMPDIR"/bin/*
                PATH="$TMPDIR/bin:$PATH" bash "$TMPDIR/repo/update.sh" --update > "$TMPDIR/log" 2>&1 \
                  || { echo "update.sh --update failed:" >&2; cat "$TMPDIR/log" >&2; exit 1; }
                grep -q 'nixos-26.05' "$TMPDIR/repo/flake.nix" \
                  || { echo "stable channel was not bumped to the released 26.05:" >&2; cat "$TMPDIR/repo/flake.nix" "$TMPDIR/log" >&2; exit 1; }
                touch $out
              '';

          # T13: no zsh alias points at a binary that is not installed or at
          # itself, and git's `visual` alias does not need gitk.
          no-dead-aliases =
            let
              cfg = self.homeConfigurations.orre.config;
              aliases = cfg.programs.zsh.shellAliases;
              dead = lib.filter (n: aliases ? ${n}) [
                "k"
                "ssh"
                "ssh-add"
                "scp"
                "nm"
              ];
            in
            pkgs.runCommand "check-no-dead-aliases"
              {
                dead = lib.concatStringsSep " " dead;
                gitVisual = cfg.programs.git.settings.alias.visual or "unset";
              }
              ''
                [ -z "$dead" ] || {
                  echo "zsh aliases to missing or identical commands: $dead" >&2
                  exit 1
                }
                [ "$gitVisual" = unset ] || {
                  echo "git alias visual still set to $gitVisual (gitk is not installed)" >&2
                  exit 1
                }
                touch $out
              '';

          # O9: the pinned skills sync runs at login and on switch (the pin is part
          # of the unit), not every 15 minutes.
          skill-sync-no-timer =
            let
              hm = self.homeConfigurations.orre.config.systemd.user;
            in
            pkgs.runCommand "check-skill-sync-no-timer"
              {
                timer = lib.boolToString (hm.timers ? kirocrew-skill-sync);
                service = lib.boolToString (hm.services ? kirocrew-skill-sync);
                wantedBy = lib.concatStringsSep "," hm.services.kirocrew-skill-sync.Install.WantedBy;
              }
              ''
                [ "$timer" = false ] || { echo "kirocrew-skill-sync.timer still exists" >&2; exit 1; }
                [ "$service" = true ] || { echo "kirocrew-skill-sync.service is gone" >&2; exit 1; }
                [ "$wantedBy" = default.target ] || { echo "service WantedBy is '$wantedBy'" >&2; exit 1; }
                touch $out
              '';

          # C24: the workstation does not install an agent spec whose rulepack
          # skill only the headless hosts ship.
          workstation-agents-no-design-sage =
            let
              script = self.homeConfigurations.orre.config.home.activation.kirocrewAgents.data;
            in
            pkgs.runCommand "check-workstation-agents-no-design-sage"
              {
                inherit script;
                passAsFile = [ "script" ];
              }
              ''
                if grep -n 'review-design-sage' "$scriptPath" >&2; then
                  echo "workstation still installs review-design-sage" >&2
                  exit 1
                fi
                grep -q 'architect' "$scriptPath" \
                  || { echo "sanity: other agents missing from the script" >&2; exit 1; }
                touch $out
              '';

          # S16: no SSH agent is forwarded to the agent host by default; use
          # `ssh -A kirocrew` when needed.
          ssh-no-agent-forwarding =
            let
              sshConfig =
                pkgs.writeText "orre-ssh-config"
                  self.homeConfigurations.orre.config.home.file.".ssh/config".text;
            in
            pkgs.runCommand "check-ssh-no-agent-forwarding" { } ''
              if grep -n 'ForwardAgent' ${sshConfig} >&2; then
                echo "ssh config forwards the agent by default" >&2
                exit 1
              fi
              grep -q '^Host kirocrew$' ${sshConfig} \
                || { echo "sanity: Host kirocrew block missing" >&2; exit 1; }
              touch $out
            '';

          # C20: repo cloning and crg registration only run where kirocrew is
          # enabled (not on the devcontainer or darwin profiles).
          clone-activation-gated =
            let
              has =
                name: profile:
                lib.boolToString (self.homeConfigurations.${profile}.config.home.activation ? ${name});
            in
            pkgs.runCommand "check-clone-activation-gated"
              {
                devClone = has "cloneRepos" "devcontainer";
                devRegister = has "crgRegisterRepos" "devcontainer";
                darwinClone = has "cloneRepos" "orre@darwin";
                orreClone = has "cloneRepos" "orre";
                orreRegister = has "crgRegisterRepos" "orre";
              }
              ''
                [ "$devClone$devRegister$darwinClone" = falsefalsefalse ] \
                  || { echo "clones still run where kirocrew is disabled: devcontainer clone=$devClone register=$devRegister, darwin clone=$darwinClone" >&2; exit 1; }
                [ "$orreClone$orreRegister" = truetrue ] \
                  || { echo "orre lost its clone or register step: clone=$orreClone register=$orreRegister" >&2; exit 1; }
                touch $out
              '';

          # C31: activation has no ssh on PATH, so `git clone git@...` died with
          # "cannot run ssh". The clone step must put openssh on the child's PATH.
          clone-activation-has-ssh =
            pkgs.runCommand "check-clone-activation-has-ssh"
              {
                text = self.homeConfigurations.orre.config.home.activation.cloneRepos.data;
                ssh = "${pkgs.openssh}/bin";
                passAsFile = [ "text" ];
              }
              ''
                grep -qF "PATH=/usr/bin:$ssh:" "$textPath" \
                  || { echo "cloneRepos must put system ssh (/usr/bin) before $ssh on PATH: nix openssh rejects Fedora's crypto-policies config" >&2; exit 1; }
                touch $out
              '';

          # T12: nothing reads KIROCREW_ROLE from the session environment; the
          # activation scripts take config.kirocrew.role directly.
          no-role-session-variable =
            pkgs.runCommand "check-no-role-session-variable"
              {
                present = lib.boolToString (
                  self.homeConfigurations.orre.config.home.sessionVariables ? KIROCREW_ROLE
                );
              }
              ''
                [ "$present" = false ] || {
                  echo "home.sessionVariables.KIROCREW_ROLE still exists" >&2
                  exit 1
                }
                touch $out
              '';

          # T17: `htop` is an alias for btm, so the real htop is not installed or
          # configured on top of it.
          htop-is-btm =
            let
              cfg = self.homeConfigurations.orre.config;
            in
            pkgs.runCommand "check-htop-is-btm"
              {
                htopEnabled = lib.boolToString cfg.programs.htop.enable;
                alias = cfg.programs.zsh.shellAliases.htop or "unset";
              }
              ''
                [ "$htopEnabled" = false ] || { echo "programs.htop is still enabled" >&2; exit 1; }
                [ "$alias" = btm ] || { echo "htop alias is '$alias', want btm" >&2; exit 1; }
                touch $out
              '';

          # C28: no zsh setting that a later part of .zshrc overrides (atuin owns
          # Ctrl-R, the tty eats Ctrl-S, starship sets the continuation prompt).
          zsh-no-dead-settings =
            let
              files = self.homeConfigurations.orre.config.home.file;
              zshText = lib.concatMapStringsSep "\n" (n: files.${n}.text) [
                ".zshenv"
                ".config/zsh/.zshenv"
                ".config/zsh/.zprofile"
                ".config/zsh/.zshrc"
              ];
            in
            pkgs.runCommand "check-zsh-no-dead-settings"
              {
                inherit zshText;
                passAsFile = [ "zshText" ];
              }
              ''
                fail=0
                grep -n "bindkey '^[RS]'" "$zshTextPath" >&2 && fail=1
                grep -n 'export PS2=' "$zshTextPath" >&2 && fail=1
                grep -n 'Ctrl-S' "$zshTextPath" >&2 && fail=1
                grep -q 'atuin init zsh' "$zshTextPath" \
                  || { echo "sanity: atuin init missing, Ctrl-R would be unbound" >&2; fail=1; }
                [ "$fail" = 0 ] || { echo "dead zsh settings present" >&2; exit 1; }
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
