# KiroCrew NixOS Infrastructure

The KiroCrew gateway runs natively (no container) on NixOS as a systemd user
service, with this repo's `./home.nix` toolset via Home Manager.

## Architecture

The gateway is installed via `curl | bash` on first boot, then managed as a
systemd user service (`kirocrew.service`) that runs `kirocrew gateway`.

**Files:**
- `flake.nix` → `nixosConfigurations.kirocrew` (local VM), `.kirocrew-ec2` (live EC2)
- `nixos/kirocrew-host.nix` — local QEMU VM host config (SSH, firewall)
- `nixos/kirocrew-ec2.nix` — EC2 host config (SSH, mount-s3, Graviton)
- `nixos/kirocrew.nix` — shared NixOS module (packages, kiro-cli link, glab adapter)
- `kirocrew-config.nix` — Home Manager module (repos.toml, known_hosts, role option)
- `kirocrew-service.nix` — Home Manager module (systemd user service)
- `sops.nix` — Home Manager module (age-encrypted secrets, conditional activation)
- `nixos/kirocrew_ec2/` — Python launcher for EC2 lifecycle management

All three NixOS outputs (VM, EC2, AMI) share the same `kirocrewModules` list
defined in `flake.nix`. Differences are only at the NixOS system level.

## Deploy

```bash
# Live EC2 (builds on the remote, no cross-compile):
nixos-rebuild switch --flake .#kirocrew-ec2 \
  --target-host root@<ip> --build-host root@<ip>

# Or use the launcher (handles infra + deploy + repo sync):
./nixos/launch-ec2 start

# Local VM:
nixos-rebuild build-vm --flake .#kirocrew
./result/bin/run-kirocrew-vm
```

## Secrets

Managed by sops-nix. The age private key is bootstrapped from 1Password by the
launcher (`launch-ec2 start`). Secrets are decrypted to `$XDG_RUNTIME_DIR/secrets/`
at activation time. The gateway uses `git-ssh-key` for Git clone/pull operations.

On hosts without an age key (local VM, workstation), sops-nix skips decryption
and the gateway falls back to the SSH agent socket.

## Dashboard access

```bash
ssh -NL 5476:localhost:5476 orre@kirocrew
# open http://localhost:5476/?token=...
```
