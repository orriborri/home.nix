# Requirements

## Requirement 1: All KiroCrew outputs share a common Home Manager module set

The system SHALL define a single shared list of KiroCrew-related Home Manager modules imported by every KiroCrew flake output.

1. WHEN a new KiroCrew Home Manager module is added (e.g. `kirocrew-config.nix`), THEN it SHALL appear in all three outputs (local VM, live EC2, AMI) without separate manual edits
2. WHEN `kirocrew-service.nix` is updated, THEN the change SHALL take effect on the local VM, live EC2, and AMI equally
3. WHEN a module is intentionally excluded from one output, THEN the exclusion SHALL be explicit (via an option guard, not by omitting the import)

## Requirement 2: Secrets are conditionally enabled, not conditionally imported

The sops-nix integration SHALL be importable on all outputs but activate only where an age key is available.

1. WHEN the sops-nix Home Manager module is imported on a host without `~/.config/sops/age/keys.txt`, THEN it SHALL not fail evaluation or activation
2. WHEN the sops-nix module is imported and a key file is present, THEN it SHALL decrypt secrets normally
3. WHEN the local workstation profile imports the shared module set, THEN sops SHALL remain inactive unless a key file exists (workstation uses 1Password agent, not age)

## Requirement 3: No filesystem probing for host detection

The system SHALL not use `builtins.pathExists` to determine the target host's role or capabilities.

1. WHEN code needs to distinguish EC2 from VM from workstation, THEN it SHALL use an explicit option (e.g. `kirocrew.role` or a NixOS module argument)
2. WHEN `builtins.pathExists /etc/NIXOS` or `/run/ostree-booted` is used to detect the evaluator's own OS, THEN it SHALL remain acceptable for per-user Home Manager (it reflects the build host = target host)
3. WHEN a NixOS configuration is evaluated on a different host (cross-deploy), THEN build decisions SHALL NOT depend on `builtins.pathExists` checks that read the evaluator's filesystem

## Requirement 4: The gateway user service is defined on all KiroCrew NixOS outputs

The `kirocrew-service.nix` module SHALL be imported in all KiroCrew NixOS outputs so the gateway starts automatically after deployment.

1. WHEN `nixosConfigurations.kirocrew` (local VM) is built, THEN it SHALL include `kirocrew-service.nix`
2. WHEN `packages.x86_64-linux.kirocrew-ami` is built, THEN it SHALL include `kirocrew-service.nix`
3. WHEN the service is not desired on a particular output in the future, THEN it SHALL be disabled via `systemd.user.services.kirocrew.enable = false` rather than by removing the import

## Requirement 5: `glab` adapter installation moves to NixOS module

The root-owned copy of `glab` into `/usr/local/libexec/kirocrew/` SHALL be performed by the NixOS system module, not by a Home Manager activation script using `sudo`.

1. WHEN `nixos/kirocrew.nix` is evaluated, THEN it SHALL install a root-owned `glab` wrapper or symlink in the system path
2. WHEN `kirocrew-service.nix` is evaluated, THEN it SHALL NOT use `sudo` to copy binaries
3. WHEN the NixOS module installs `glab`, THEN it SHALL use the same Nix store path as the Home Manager-installed package (no version drift)
