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
- `pasta-service.nix` — Home Manager module (pasta daemon, builds from source)
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

Access is SSM-only. There is no Tailscale, VPN, or public inbound port, and no
browser terminal. The launcher holds an AWS Session Manager port-forward open
and points a loopback URL at it; the security group needs no inbound rule.

Requires the AWS Session Manager plugin locally (`session-manager-plugin` on
`PATH`) and an instance profile carrying `AmazonSSMManagedInstanceCore`.

1. Deploy / start the instance:
   ```bash
   ./nixos/launch-ec2 start
   ```

2. Open the KiroCrew portal (SSM tunnel + browser):
   ```bash
   ./nixos/launch-ec2 portal   # opens http://127.0.0.1:7780
   ```
   Keep the command running; it reconnects automatically if the SSM session
   drops. Press Ctrl+C to close the tunnel. While the portal is open, the
   operator's forwarded 1Password agent lets the gateway push to git (each
   signature gated by a 1Password prompt); closing the portal revokes it.

3. Open browser Obsidian (Xpra HTML5 over the same SSM tunnel):
   ```bash
   ./nixos/launch-ec2 obsidian   # opens https://127.0.0.1:14500
   ```
   The Xpra endpoint uses a self-signed certificate, so the browser warns on
   first connect — expected for a tunnelled loopback service.

4. Get an interactive shell over SSH-over-SSM (with X11 forwarding):
   ```bash
   ./nixos/launch-ec2 ssh       # or: ./nixos/launch-ec2 connect
   ```

### Terminal multiplexer (Zellij)

There is no web terminal. Reach the persistent Zellij session over the
SSH-over-SSM connection instead — either interactively:

```bash
./nixos/launch-ec2 ssh
zellij attach --create kirocrew   # shared persistent session on the instance
```

or via the local `kirocrew-zellij` helper, which opens COSMIC Terminal and
runs `zellij attach --create` over SSH (requires a `kirocrew` SSH host alias
pointing through the SSM ProxyCommand):

```bash
./nixos/kirocrew-zellij            # defaults to the "kirocrew" session
```

