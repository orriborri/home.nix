# ADR-001: KiroCrew Remote Workspace Data and Indexing Model

## Status

Accepted on 2026-09-03 and deployed to the existing EC2 host (`i-05d4aaf8ee73fc07f`). Live verification passed: the vault mounts read-only from S3, all 15 repositories synchronize through protected mirrors, the Code Review Graph daemon supervises every repository under `/var/lib/code`, and the gateway has read-only legacy `.kiro` access.

## Context

The persistent NixOS KiroCrew host needs current source repositories, searchable Code Review Graph indexes, access to the canonical Obsidian vault, and compatibility with historical Kiro state. The design must avoid giving credentialed processes control over agent-writable Git metadata, avoid concurrent vault writers, preserve local data during migration, and keep long-running index maintenance supervised.

The existing host had these gaps:

- Repositories existed only under the operator home and were refreshed only during launcher deployments.
- The proposed `/var/lib/code` tree was empty and had no synchronization timer.
- Code Review Graph ran as an imperative daemon against old paths and was not supervised by systemd.
- Remote rclone bisync failed because rclone attempted to write a filter checksum beside an immutable Nix-store file.
- The S3 bucket was mounted only as a separate inspection path, while the gateway expected `/var/lib/vault`.
- Historical Kiro state remained at `/home/orre/.kiro`, but the hardened gateway hid operator homes.

## Decision

### 1. The workstation is the vault writer

> **Superseded by [ADR-002](002-kirocrew-vault-git-crypt.md) (2026-09-04):** the
> vault moved from a read-only S3 mount to a git-crypt-encrypted git repository
> that KiroCrew manages read-write. The description below is retained for
> historical context.

The workstation keeps the local canonical working copy at `/home/orre/Obsidian/Readpeak`. Its Home Manager `vault-sync` user timer runs conflict-preserving rclone bisync with `s3://readpeak-vault-sync` every ten minutes.

The remote host does not run rclone. It mounts the S3 bucket directly and read-only at `/var/lib/vault` with Mountpoint for Amazon S3. KiroCrew and Pasta require this mount and receive read-only access. Remote vault mutation is deferred.

Before the first direct mount, pre-existing files under `/var/lib/vault` are moved to `/var/lib/vault-before-s3-mount`. They are preserved rather than overwritten or deleted.

### 2. Credentialed fetches and agent working trees are separated

`config/repos.toml` remains the repository source of truth. Repositories targeting `headless` are fetched at boot and every fifteen minutes.

The fetch pipeline has two trust domains:

1. `repo-fetch.service` runs as `orre`, uses the Git SSH credential, and updates protected bare mirrors under `/var/lib/kirocrew-repo-mirrors`.
2. `repo-sync.service` runs as `kirocrew`, has no Git credential, and clones or fast-forwards working trees under `/var/lib/code` from the local mirrors.

Dirty, diverged, missing, or failed repositories are reported and preserved. Automation never resets or force-updates a working tree.

### 3. Code Review Graph is updated and supervised declaratively

The remote launcher installs the validated Code Review Graph version `2.3.8`.

After repository synchronization, `code-review-graph-sync.service`:

- installs graph metadata when missing;
- rebuilds when a fingerprint of repository HEAD plus working-tree state changes;
- registers every available repository idempotently; and
- records successful fingerprints under `/var/lib/code-review-graph`.

`code-review-graph-daemon.service` runs the watcher in the foreground under systemd with restart supervision. A repository synchronization or graph failure does not prevent the daemon from supervising healthy repositories.

### 4. Legacy Kiro state is exposed at its original path, read-only

For UI and path compatibility, the gateway receives direct access to `/home/orre/.kiro` rather than an alias.

A prerequisite service grants the `kirocrew` identity traverse-only (`--x`) access to `/home/orre` and recursive/inherited read (`r-X`) access to `/home/orre/.kiro`. The gateway uses `ProtectHome=tmpfs` and selectively exposes `/home/orre/.kiro` with `BindReadOnlyPaths`. Other operator-home content remains hidden, and the gateway cannot modify the legacy tree.

This is an explicit security exception. The tree includes configuration, sessions, trust state, logs, and token-related state. KiroCrew may read this information because compatibility requires it, but write access remains prohibited.

### 5. MCP OAuth tokens are provisioned from the workstation

Remote MCP servers reached through `mcp-remote` (for example Linear) authenticate with a browser OAuth flow that only a human can complete. `launch-ec2 auth <target>` runs that flow on the workstation, where `mcp-remote` caches the token under `~/.mcp-auth/mcp-remote-v1/`. Only the actual credential file — not the `code_verifier` or `client_info` companion files — is copied over SSM into the gateway's `/var/lib/kirocrew/.mcp-auth/mcp-remote-v1/` (mode 600, owned `kirocrew`), and then `kirocrew-gateway.service` is restarted so the server picks up the cached token.

## Alternatives Considered

### Run rclone bisync on both workstation and remote

Rejected. Two independent bidirectional writers increase conflict and lock-recovery risk. The remote only needs a current read view, so the workstation remains the sole synchronizing writer.

### Use a writable S3 mount on the remote

Rejected. Mountpoint for Amazon S3 does not provide the full atomic rename, locking, or concurrency semantics expected by a local Obsidian vault. A read-only mount makes those limitations explicit.

### Let KiroCrew pull directly from Git remotes

Rejected. Agent-writable Git configuration, hooks, and filters must not be processed by a command holding the SSH credential. Protected mirrors isolate credentialed network fetches from agent-owned working trees.

### Refresh repositories and graphs only during deployment

Rejected. Deploy-only refreshes become stale between rebuilds, and the old CRG daemon was not guaranteed to start after reboot. Timers and supervised services make freshness and lifecycle independent of the launcher.

### Copy or alias selected legacy Kiro data

Rejected for the current migration because the UI may depend on original paths and a partial copy could omit required state. Direct path compatibility was chosen with read-only namespace enforcement and an acknowledged disclosure risk.

## Consequences

### Positive

- The workstation remains the single vault writer.
- The remote sees current S3-backed vault content without local synchronization state.
- Git credentials never enter agent-owned repository operations.
- Dirty work is preserved automatically.
- Repository and graph freshness no longer depends on deployments.
- CRG watcher lifecycle is observable and restartable through systemd.
- Existing UI paths for historical Kiro state remain valid.

### Negative

- The remote cannot create or update vault notes.
- S3 changes become visible according to Mountpoint cache behavior rather than local filesystem notifications.
- Initial graph construction may consume substantial CPU, memory, and disk.
- The legacy `.kiro` exception exposes sensitive historical state to the KiroCrew identity.
- Code Review Graph installation is version-pinned but still performed by the launcher rather than packaged fully in the Nix image.
- The EC2 IAM role currently retains broader S3 object permissions than the read-only mount requires; narrowing IAM is a separate approval-gated change.

## Deployment and Rollback

Activation requires explicit human approval because it changes ACLs, moves existing local vault files, mounts S3 at the live vault path, creates repository mirrors and working trees, and builds persistent graph data.

Rollback of the NixOS service configuration uses the previous NixOS generation. Persistent additions are retained for inspection:

- `/var/lib/vault-before-s3-mount`
- `/var/lib/kirocrew-repo-mirrors`
- `/var/lib/code`
- `/var/lib/code-review-graph`

Do not remove those paths as part of an automatic rollback.

## Verification

After activation:

1. Confirm `/var/lib/vault` is a read-only S3 mount containing expected objects.
2. Confirm no remote `vault-sync` unit exists and the workstation timer remains active.
3. Confirm repository fetch and checkout services complete and the timer is scheduled.
4. Confirm `kirocrew` cannot write protected mirrors.
5. Confirm all available repositories are registered and the CRG daemon is active.
6. Confirm KiroCrew can read but not write `/home/orre/.kiro` and `/var/lib/vault`.
7. Confirm unrelated `/home/orre` content remains inaccessible.
8. Reboot and repeat mount, timer, daemon, and permission checks.

## References

- [`nixos/kirocrew-development-workspace-plan.md`](../../nixos/kirocrew-development-workspace-plan.md)
- [`nixos/kirocrew-vault.nix`](../../nixos/kirocrew-vault.nix)
- [`nixos/kirocrew-code.nix`](../../nixos/kirocrew-code.nix)
- [`nixos/kirocrew-services.nix`](../../nixos/kirocrew-services.nix)
- [`vault-sync.nix`](../../vault-sync.nix)
- Canonical project note: `/home/orre/Obsidian/Readpeak/1. Projects/KiroCrew Remote Workspace.md`
