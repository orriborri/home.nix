# Tasks

## 1. Define `kirocrewModules` in `flake.nix`

- [ ] 1.1 Add a `kirocrewModules` binding in the `let` block listing all shared KiroCrew HM modules
- [ ] 1.2 Include: `./home.nix`, `./packages/kiro.nix`, `./kirocrew-config.nix`, `./kirocrew-service.nix`, `sops-nix.homeManagerModules.sops`, `./sops.nix`
- [ ] 1.3 Replace `nixosConfigurations.kirocrew` HM imports with `imports = kirocrewModules;`
- [ ] 1.4 Replace `nixosConfigurations.kirocrew-ec2` HM imports with `imports = kirocrewModules;`
- [ ] 1.5 Replace `packages.x86_64-linux.kirocrew-ami` HM imports with `imports = kirocrewModules;`
- [ ] 1.6 Set `kirocrew.enable = true; kirocrew.role = "headless";` in all three output HM configs

## 2. Make sops activation conditional on key file presence

- [ ] 2.1 Update `hasSops` in `kirocrew-service.nix` to: `hasSops = (config.sops.secrets or {}) ? "git-ssh-key";`
- [ ] 2.2 Verify `sops.nix` does not fail evaluation when the key file is absent (sops-nix handles this gracefully)
- [ ] 2.3 Add a comment in `sops.nix` explaining that the module is imported on all outputs but only activates where the age key exists

## 3. Move `glab` adapter to `nixos/kirocrew.nix`

- [ ] 3.1 Add `system.activationScripts.kirocrew-glab` to `nixos/kirocrew.nix` that symlinks `${pkgs.glab}/bin/glab` to `/usr/local/libexec/kirocrew/glab`
- [ ] 3.2 Remove the `home.activation.kiroCli` block from `kirocrew-service.nix` (the `sudo cp glab` logic)
- [ ] 3.3 Verify `pkgs.glab` is available in the NixOS module scope (add to `environment.systemPackages` if needed)

## 4. Replace `builtins.pathExists` in NixOS-evaluated modules

- [ ] 4.1 Audit `packages/kiro.nix` for `builtins.pathExists` usage — replace with `config.kirocrew.role` check
- [ ] 4.2 Audit `vault-sync.nix` for `builtins.pathExists` usage — replace with `config.kirocrew.role` check
- [ ] 4.3 Keep `home.nix` detection (`isNixOS`, `isSilverblue`) as-is (standalone HM evaluates on target)
- [ ] 4.4 Add comment in `home.nix` explaining why `builtins.pathExists` is acceptable there but not in NixOS-composed modules

## 5. Update `extraSpecialArgs` for parity

- [ ] 5.1 Verify all three outputs pass the same `extraSpecialArgs` (except `nixgl` which is Linux-only and already guarded)
- [ ] 5.2 Remove `nixgl` from the `kirocrew-ec2` args if it's aarch64 (nixGL doesn't support aarch64) -- already correct
- [ ] 5.3 Ensure `sops-nix` input is available to all outputs (it's in the flake inputs, just needs to be passed where used)

## 6. Remove stale documentation and dead assets

- [ ] 6.1 Delete or rewrite `nixos/kirocrew.md` (describes removed OCI container architecture)
- [ ] 6.2 Delete `nixos/seccomp/kirocrew-seccomp.json` (no consumer exists)
- [ ] 6.3 Update `README.md` or add a `nixos/README.md` describing the current native architecture

## 7. Validate

- [ ] 7.1 Run `nix flake check` -- all outputs evaluate without error
- [ ] 7.2 Run `nix build .#packages.x86_64-linux.kirocrew-ami --dry-run` -- verify AMI includes service unit
- [ ] 7.3 Build local VM: `nixos-rebuild build-vm --flake .#kirocrew` -- verify it includes kirocrew.service in systemd units
- [ ] 7.4 Deploy EC2: `launch-ec2 start` -- verify gateway starts and repos sync from manifest
- [ ] 7.5 Verify no `sudo` commands remain in `kirocrew-service.nix`
- [ ] 7.6 Verify `glab` at `/usr/local/libexec/kirocrew/glab` is a symlink to the Nix store after NixOS rebuild
