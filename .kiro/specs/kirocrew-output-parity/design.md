# Design

## Context

The flake currently defines three KiroCrew system/image outputs. Their Home Manager module lists diverge:

| Output | HM Modules |
|--------|-----------|
| `nixosConfigurations.kirocrew` (local VM) | `home.nix`, `packages/kiro.nix` |
| `nixosConfigurations.kirocrew-ec2` (live) | `home.nix`, `packages/kiro.nix`, `kirocrew-service.nix`, `sops-nix`, `sops.nix` |
| `packages.x86_64-linux.kirocrew-ami` | `home.nix`, `packages/kiro.nix` |

The local VM and AMI lack the gateway service, so deploying them produces a host that installs KiroCrew but doesn't run it. The AMI is meant to be the image backing the EC2 output, yet it is not equivalent.

Additionally, `kirocrew-service.nix` uses `sudo` to copy `glab` into a root-owned path — a privilege escalation that belongs in the NixOS system module.

#[[file:flake.nix]]
#[[file:kirocrew-service.nix]]
#[[file:nixos/kirocrew.nix]]
#[[file:sops.nix]]

## Goals / Non-Goals

**Goals:**
- Define one `kirocrewModules` list and reuse it in all three outputs
- Make sops conditional on key presence (import everywhere, activate conditionally)
- Move the `glab` root-owned adapter to `nixos/kirocrew.nix`
- Remove the `sudo cp` from `kirocrew-service.nix`

**Non-Goals:**
- Packaging KiroCrew CLI as a Nix derivation (separate future spec)
- Replacing the `curl | bash` installer (separate future spec)
- Changing the EC2 launcher's deploy workflow
- Removing `builtins.pathExists` from `home.nix` (acceptable for standalone HM where evaluator = target)

## Decisions

### 1. Define `kirocrewModules` in `flake.nix`

Introduce a local binding in the flake's `let` block:

```nix
kirocrewModules = [
  ./home.nix
  ./packages/kiro.nix
  ./kirocrew-config.nix       # from spec #1
  ./kirocrew-service.nix
  sops-nix.homeManagerModules.sops
  ./sops.nix
];
```

All three outputs use this list. The local VM and AMI gain the service and sops imports they currently lack.

**Rationale:** Adding or removing a KiroCrew HM module means editing one place. No more output-specific module lists to keep in sync.

**Alternative:** A Home Manager meta-module that imports everything — rejected because it adds indirection and makes it harder to see what's imported at the flake level.

### 2. Conditional sops via `sops.age.keyFile` existence check at activation

`sops.nix` already points to `~/.config/sops/age/keys.txt`. The sops-nix module only attempts decryption when the key file exists at activation time. If the file is absent, the service simply won't have the decrypted secret and the gateway falls back to the SSH agent socket (which is how it works on the workstation today).

To make this robust, guard the `GIT_SSH_COMMAND` environment variable in the service:

```nix
# kirocrew-service.nix (updated)
Environment = [
  ...
]
++ lib.optionals hasSops [
  "GIT_SSH_COMMAND=ssh -i %t/secrets/git-ssh-key ..."
];
```

The existing `hasSops` detection works (`config.sops or null != null`), but refine it to also check that the specific secret is declared:

```nix
hasSops = (config.sops.secrets or {}) ? "git-ssh-key";
```

**Rationale:** sops-nix is designed to be safe when the key file is absent — it logs a warning and skips decryption. The guard already exists; we just import it everywhere.

### 3. Move `glab` adapter to `nixos/kirocrew.nix`

Remove from `kirocrew-service.nix`:
```nix
# DELETE: home.activation.kiroCli
```

Add to `nixos/kirocrew.nix`:
```nix
# Install glab where the KiroCrew gateway can find it (root-owned, trusted)
environment.systemPackages = [ pkgs.glab ];

# Or, if the gateway specifically needs /usr/local/libexec/kirocrew/glab:
system.activationScripts.kirocrew-glab = lib.stringAfter [ "users" ] ''
  mkdir -p /usr/local/libexec/kirocrew
  ln -sf ${pkgs.glab}/bin/glab /usr/local/libexec/kirocrew/glab
'';
```

**Rationale:** Root-owned system paths should be managed by the NixOS system module, not a user-level Home Manager activation using `sudo`. The NixOS activation runs as root naturally. Using a symlink to the Nix store path means no version drift between HM-installed and system-installed `glab`.

### 4. Remove `builtins.pathExists` from NixOS-evaluated modules

For `packages/kiro.nix` and `vault-sync.nix`, which use `builtins.pathExists` to detect NixOS/EC2, replace with the explicit `kirocrew.role` option (from spec #1):

```nix
# Before (unreliable during cross-deploy evaluation):
isEC2 = builtins.pathExists /sys/devices/virtual/dmi/id/product_uuid;

# After:
isHeadless = config.kirocrew.role == "headless";
```

The `home.nix` detection of `isNixOS`/`isSilverblue` remains acceptable because standalone Home Manager always evaluates on the target host.

**Rationale:** When `nixos-rebuild switch --flake .#kirocrew-ec2` evaluates on the developer's Fedora laptop, `builtins.pathExists /etc/NIXOS` returns `false` even though the target is NixOS. Explicit options are evaluation-host-independent.

### 5. Output definitions after refactor

```nix
nixosConfigurations.kirocrew = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    ./nixos/kirocrew-host.nix
    ./nixos/kirocrew.nix
    home-manager.nixosModules.home-manager
    {
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { ... };
      home-manager.users.orre = { ... }: {
        imports = kirocrewModules;
        kirocrew.enable = true;
        kirocrew.role = "headless";
      };
    }
  ];
};

nixosConfigurations.kirocrew-ec2 = nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [
    ./nixos/kirocrew-ec2.nix
    ./nixos/kirocrew.nix
    home-manager.nixosModules.home-manager
    {
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { ... };
      home-manager.users.orre = { ... }: {
        imports = kirocrewModules;
        kirocrew.enable = true;
        kirocrew.role = "headless";
      };
    }
  ];
};

packages.x86_64-linux.kirocrew-ami = nixos-generators.nixosGenerate {
  system = "x86_64-linux";
  format = "amazon";
  modules = [
    ./nixos/kirocrew-ec2.nix
    ./nixos/kirocrew.nix
    home-manager.nixosModules.home-manager
    {
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { ... };
      home-manager.users.orre = { ... }: {
        imports = kirocrewModules;
        kirocrew.enable = true;
        kirocrew.role = "headless";
      };
    }
  ];
};
```

All three are structurally identical in their HM section. The only differences are `system`, host module, and NixOS-level config.

## Risks / Trade-offs

- **[sops on local VM]** Importing sops-nix on a VM without a key file will log a warning during activation. Mitigation: the warning is harmless and expected.
- **[Service starts without secrets on VM]** The gateway may fail to authenticate Git if the age key is absent. Mitigation: the VM is a development/test target; the user bootstraps the key or uses SSH agent.
- **[Breaking change to AMI]** The AMI gains a gateway service it didn't previously have. Mitigation: the AMI is meant to be a fully functional KiroCrew image — adding the service is the fix, not a regression.
- **[NixOS module assumes glab exists]** `nixos/kirocrew.nix` symlinks `pkgs.glab`. Mitigation: `glab` is already in `development.nix` packages; adding it to the NixOS module ensures it's available system-wide.
