# KiroCrew NixOS Infrastructure

The KiroCrew gateway runs natively (no container) on a NixOS EC2 host as a
**system** service, `kirocrew-gateway.service`, under the dedicated
unprivileged `kirocrew` user. The operator account `orre` gets this repo's
`./home.nix` toolset through Home Manager, but the gateway itself is not a
user service there (`kirocrew.role = "headless"` disables the workstation
unit).

## Architecture

- The gateway is built from source on the box: `kirocrew-gateway.service`
  runs the shared source builder (`kirocrew-source-build.nix`, pinned to the
  tag in `kirocrew-source-tag.nix`) as an `ExecStartPre`, then starts the
  resulting venv under `/var/lib/kirocrew/.local/share/kirocrew-source/current`.
  No curl-pipe-bash install path exists.
- Agent crews are registered by `kirocrew-register-agents.service`; their
  specs come from the `kirocrew-review-agents`, `-dev-crew` and `-assistant`
  activation scripts.
- The MCP servers the gateway spawns (kb-evidence, cfm-tips, slack) are built
  and wired by `kirocrew-mcp-servers.nix`; `kirocrew-mcp-config.service`
  writes the gateway's `mcp.json`.
- Pasta (`pasta.nix`) runs as the `pasta` user: a daemon plus two timers that
  index the vault and fetch external sources into `/var/lib/pasta/data`,
  which the gateway reads through the `vault-readers` group.
- The Obsidian vault is a git-crypt-encrypted git checkout at `/var/lib/vault`
  owned by KiroCrew (`kirocrew-vault-git.nix`). There is no S3 mount; see
  `docs/adr/002` for the history.
- While `launch-ec2 portal` is open, the operator's 1Password agent socket
  is relayed to the gateway (`kirocrew-1p-relay.nix`) so it can push to git;
  each signature is gated by a 1Password prompt. Closing the portal revokes it.

**Files:**

- `flake.nix` → `nixosConfigurations.kirocrew` (local QEMU VM),
  `nixosConfigurations.kirocrew-ec2` (live EC2, aarch64),
  `packages.<system>.kirocrew-ami` (baked AMI via nixos-generators)
- `nixos/kirocrew-ec2.nix` — EC2 host: amazon-image profile, SSH over SSM,
  SSM agent, zram swap, store GC, and the module imports below
- `nixos/kirocrew-host.nix` — local QEMU VM host config
- `nixos/kirocrew.nix` — shared module (packages, kiro-cli link, glab adapter)
- `nixos/kirocrew-security.nix` — users, groups, sudo, firewall
- `nixos/kirocrew-gateway.nix` — the gateway unit and its oneshots
- `nixos/kirocrew-services.nix` — operator `kirocrew` wrapper, tmpfiles rules
- `nixos/kirocrew-mcp-servers.nix` — MCP server venv builders and launchers
- `nixos/kirocrew-1p-relay.nix` — 1Password agent socket relay
- `nixos/pasta.nix` — pasta daemon, timers and source build
- `nixos/kirocrew-sops.nix` — system-level sops-nix secrets
- `nixos/kirocrew-vault-git.nix`, `-code.nix`, `-obsidian-xpra.nix`,
  `-ollama.nix`, `-codex.nix`, `-review-agents.nix`, `-review-skills.nix`,
  `-steering.nix`, `-assistant.nix`, `-dev-crew.nix`, `-disk-check.nix`
  — the remaining host modules, each with a header comment
- `nixos/kirocrew_ec2/` — Python launcher for the EC2 lifecycle
  (`nixos/launch-ec2`)
- `kirocrew-config.nix`, `kirocrew-service.nix`, `pasta-service.nix`,
  `sops.nix` — Home Manager modules shared with the workstation profile; on
  the EC2 host they run for `orre` with `kirocrew.role = "headless"`, which
  disables the user-level gateway and pasta units

All three NixOS outputs (VM, EC2, AMI) share the same `kirocrewModules` list
for the `orre` Home Manager profile in `flake.nix`. Differences are at the
NixOS system level: the VM imports `kirocrew-host.nix`, the EC2 and AMI
outputs import `kirocrew-ec2.nix`.

## Deploy

```bash
# Live EC2 (builds on the remote, no cross-compile):
nixos-rebuild switch --flake .#kirocrew-ec2 \
  --target-host root@<instance-id> --build-host root@<instance-id>

# Or use the launcher (infra + age key + rebuild + state sync):
./nixos/launch-ec2 start

# Local VM:
nixos-rebuild build-vm --flake .#kirocrew
./result/bin/run-kirocrew-vm
```

`launch-ec2 start` reaches the box over SSM (`NIX_SSHOPTS` with the SSM
ProxyCommand), places the age key, runs `nixos-rebuild switch`, restarts the
gateway and pasta, and syncs local state. Other launcher commands:
`portal`, `obsidian`, `ssh`/`connect`, `stop`, `destroy`, `rebuild`,
`resize`, `new`, `sync-state`, `auth`, `token`, `codex`.

## Secrets

Managed by sops-nix at the **system** level (`nixos/kirocrew-sops.nix`),
decrypted at activation with the host age key at `/var/lib/sops-nix/key.txt`.
`launch-ec2 start` installs that key (and the same key for `orre` at
`~/.config/sops/age/keys.txt`) from the 1Password item `kirocrew-age`
(falling back to the operator's `~/.config/sops/age/keys.txt`) if it is
missing. Secrets land as root-provisioned files owned by their consumer, e.g.
`/var/lib/kirocrew/secrets/{vault-git-token,vault-git-crypt-key,slack-token,
cfm-tips-aws-*}` and `/var/lib/pasta/secrets/*`.

Git access to the vault uses an HTTPS GitLab deploy token fed through
`GIT_ASKPASS`, not an SSH key. The gateway's `SSH_AUTH_SOCK` points at the
1Password relay socket (`/run/kirocrew/1p-agent.sock`), which only exists
while the portal is open.

The Home Manager `sops.nix` module is also imported for `orre` on every
output and is always active: a missing `~/.config/sops/age/keys.txt` fails
the switch for that user profile rather than being skipped.

## Access model

Access is SSM-only. The security group needs no inbound rule and the NixOS
firewall opens no port (`networking.firewall.allowedTCPPorts = [ ]`,
`services.openssh.openFirewall = false`). sshd still runs, key-only with
`PermitRootLogin prohibit-password`, and is reached through
`AWS-StartSSHSession` as root; `orre` holds passwordless sudo via `wheel`,
the `kirocrew`, `pasta` and `claude-remote` users have none. The instance profile must carry
`AmazonSSMManagedInstanceCore`. There is no Tailscale, VPN, public inbound
port, or browser terminal.

## Claude Remote Control sandbox

`claude-remote.service` (`kirocrew-claude-remote.nix`) runs `claude
remote-control --name kirocrew --spawn worktree` so a session on claude.ai/code
can work on the box without being able to publish anything.

- **Uid.** `claude-remote` is a system user with home `/var/lib/claude-remote`
  (0700) and workspace `/var/lib/claude-remote/workspace`. It is not a nix
  trusted user, owns no sops secret and holds no ssh key or forge token.
- **Unit.** The shared hardening set (`kirocrew-hardening.nix`), plus
  `IPAddressDeny = any` / `IPAddressAllow = localhost`, which covers every
  session and shell the unit spawns. `ANTHROPIC_API_KEY` and
  `ANTHROPIC_AUTH_TOKEN` are unset. No `CLAUDE_CODE_DISABLE_*` variable is set:
  they would disable Remote Control.
- **Network.** The only way out is the loopback proxy (`kirocrew-claude-egress.nix`,
  tinyproxy on `127.0.0.1:8888`): default-deny, exact-host allowlist, CONNECT
  to 443 only. The host list is in that file: Claude API and login, npm, PyPI,
  crates, GitHub read hosts and the NixOS cache and channel hosts. IMDS is not
  on it. Every allowed host is a possible exfil channel (accepted risk).
  `nix-daemon.service` is confined the same way, so `nix-shell -p` from the
  uid substitutes through the proxy; uncached builds that fetch from other
  hosts fail by design. Deploys are not affected: `nixos-rebuild
  --target-host` runs nix in the SSH session, outside that unit.
  Plain-http tools ignore uppercase `HTTP_PROXY` (curl does), so rely on
  `HTTPS_PROXY`.
- **No push.** The uid has no credentials, and `GIT_CONFIG_GLOBAL` points at the
  store-backed `/etc/claude-remote/gitconfig`, which rewrites `git@`,
  `ssh://`, `https://` and `http://` push URLs to `invalid-push://`. Fetching
  still works. Results leave the box as a patch or bundle that a human reviews
  and pushes from the laptop. A server-side guard (protected branches) is not
  in this repo (BACKLOG F1.8).
- **First login (human, once, after a deploy).** The unit has
  `ConditionPathExists=/var/lib/claude-remote/.claude/.credentials.json`, so it
  stays inactive, with no crash loop, until the uid has logged in:
  1. `sudo -u claude-remote -H claude auth login` and paste the code.
  2. In the workspace, run `sudo -u claude-remote -H env
     HTTPS_PROXY=http://127.0.0.1:8888 claude remote-control --spawn session`
     once to accept "Enable Remote Control?" and the trust prompt.
  3. `systemctl start claude-remote`, then open the session from claude.ai/code.
  The CLI warns 3 days before the login expires; repeat step 1 then.
- **Ticket sessions.** `./nixos/launch-ec2 analyze RP-123` opens Claude on
  your terminal as the uid, running `/analyze-ticket RP-123` with Remote
  Control on (named `RP-123 analyze-ticket` in claude.ai/code) and the
  code-review-graph MCP server loaded. It goes through `claude-remote-session`
  → `claude-remote-sandbox`, a transient unit with the same settings as
  `claude-remote.service` (one `sandbox` attrset in the module). Needs the
  first login above. The session ends when the SSM connection drops.
  `./nixos/launch-ec2 implement RP-123` does the same with
  `/implement-ticket`; it refuses until `workspace/RP-123/analysis.md`
  exists, and re-running it resumes from the ticket's `todo.md`.
- **What the tests cover.** The flake checks `ec2-claude-egress-proxy`,
  `ec2-nix-daemon-egress`, `ec2-claude-remote-uid` and `ec2-claude-remote-unit`
  assert the rendered config. The VM test `claude-remote-sandbox`
  (`nixos/tests/claude-remote.nix`) runs the real modules with a probe in place
  of `claude`, and shows from inside the unit that the allowed host works
  through the proxy, another host and IMDS are refused, direct connections
  fail, an https push is aborted and the unit is inactive until the credentials
  file exists. It does not cover `nix-shell -p`, whether fixed-output fetches
  honour the daemon's proxy variables, the live Remote Control connection or
  the prompts above; those are checked on the box (BACKLOG F1.7).

## Dashboard access

The launcher holds an AWS Session Manager port-forward open and points a
loopback URL at it. Requires the AWS Session Manager plugin locally
(`session-manager-plugin` on `PATH`).

1. Deploy / start the instance:
   ```bash
   ./nixos/launch-ec2 start
   ```

2. Open the KiroCrew portal (SSM tunnel + browser):
   ```bash
   ./nixos/launch-ec2 portal   # opens http://127.0.0.1:7780 (remote 5476)
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
