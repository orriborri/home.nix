# KiroCrew NixOS Development Workspace Plan

## Status

Accepted on 2026-09-02 as the target architecture. This approval authorizes Phase 0 reconciliation only. Every approval gate in this plan remains in force; security, IAM, network, infrastructure, vault-storage, credential, and destructive migration changes still require separate human approval.

## Accepted implementation decisions — 2026-09-03

This section records the approved near-term implementation for the existing EC2 workspace. It supersedes conflicting statements elsewhere in this plan for this deployment; the broader Vault Writer, Crew Cloud, and AMI architecture remains a future target. The configuration has passed Nix evaluation, Python compilation, diff checks, and an `aarch64-linux` remote dry-build, but has not yet been activated with `nixos-rebuild switch`.

Formal decision record: [ADR-001: KiroCrew Remote Workspace Data and Indexing Model](../docs/adr/001-kirocrew-remote-workspace.md).

### Vault ownership and access

- The workstation remains the only vault writer. Home Manager runs conflict-preserving rclone bisync between `/home/orre/Obsidian/Readpeak` and `s3://readpeak-vault-sync` every ten minutes.
- The remote KiroCrew host does not run rclone. It mounts `s3://readpeak-vault-sync` directly and read-only at `/var/lib/vault` with Mountpoint for Amazon S3.
- KiroCrew and Pasta require the S3 mount and receive read-only vault access. Remote note mutation and the Vault Writer are deferred.
- On first activation, any pre-existing local files under `/var/lib/vault` are preserved under `/var/lib/vault-before-s3-mount` before the S3 mount is established.

### Repository synchronization

- `config/repos.toml` remains the repository source of truth; only repositories targeting `headless` are synchronized.
- A credentialed `orre` service fetches each remote into a protected bare mirror under `/var/lib/kirocrew-repo-mirrors`. Agent-writable Git state is never processed with the SSH credential present.
- A separate credential-free service running as `kirocrew` clones or fast-forwards working trees under `/var/lib/code` from those local mirrors.
- Dirty or diverged working trees are preserved and reported instead of reset. Fetch runs at boot and every fifteen minutes.

### Code Review Graph

- The launcher installs the validated `code-review-graph` version `2.3.8`.
- After repository synchronization, missing graphs are installed, changed graphs are rebuilt using a HEAD-plus-working-tree fingerprint, and every repository is registered idempotently.
- `code-review-graph-daemon.service` runs the watcher in the foreground under systemd with restart supervision. A failure in one repository does not prevent the daemon from supervising healthy repositories.

### Legacy Kiro state

- The gateway receives direct read-only access to `/home/orre/.kiro` at its original path to preserve UI/path compatibility.
- A prerequisite service applies read/traverse ACLs for `kirocrew`, including defaults for new entries.
- `ProtectHome=tmpfs` continues to hide other home content; `BindReadOnlyPaths=/home/orre/.kiro` selectively exposes only the legacy Kiro tree and prevents writes from the gateway namespace.
- This is an explicit security exception: the legacy tree includes configuration, session, trust, and token-related state. The service can read that state but cannot modify it.

### Deployment gate and verification

Activation still requires explicit human approval because it changes filesystem ACLs, moves the existing local vault aside, mounts S3 at the live vault path, clones repositories, and builds persistent graph data. After activation, verify:

1. `readpeak-vault-s3-mount.service` is active and `/var/lib/vault` is a read-only mount containing the expected S3 objects.
2. The workstation `vault-sync.timer` remains active while no `vault-sync` unit exists on the remote.
3. `repo-fetch.timer`, `repo-fetch.service`, and `repo-sync.service` complete successfully; dirty repositories surface without destructive reset.
4. All expected working trees exist under `/var/lib/code` and protected mirrors under `/var/lib/kirocrew-repo-mirrors` are not writable by `kirocrew`.
5. `code-review-graph-daemon.service` is active and every available repository is registered.
6. The gateway can read but not write `/home/orre/.kiro`, can read but not write `/var/lib/vault`, and remains unable to read other operator-home paths.
7. Reboot preserves the mount, timer, daemon, and access behavior.

## Phase 0 decision and current-diff classification

The plan is approved, but the pre-existing implementation diff is rejected as-is. It mixes independently useful migration work with access expansion, credential forwarding, imperative installation, and custom-lifecycle growth that conflict with the target architecture. No pre-existing implementation file-level diff is retained unchanged; this decision record is the sole retained change.

Classification baseline:

- Fixed point: `origin/main` at `f08fce3f27876f90c9ca7d9bffbd4684d261ebdc`.
- Reviewed commit: `8734d86` (`feat(kirocrew): system-service deploy wiring + gateway home access`).
- Reviewed scope: the complete tracked diff from `origin/main` through the working tree, plus all untracked files present before this decision record was added on 2026-09-02.
- Decision: do not deploy, merge, or treat the pre-existing implementation diff as the approved implementation.

| Path | Classification | Required disposition |
|---|---|---|
| `nixos/kirocrew-development-workspace-plan.md` | Retain | Keep this accepted target architecture and Phase 0 decision record. Approval gates remain binding. |
| `nixos/kirocrew-ec2.nix` | Revert | Remove the writable ttyd shell running as the administrator identity. Reintroduce only SSM-first access and Phase 1 sandbox verification in a separate change. |
| `nixos/kirocrew-security.nix` | Revert | Remove passwordless administrator sudo and any premature access expansion. Add identities and permissions only within the phase that verifies their boundaries. |
| `nixos/kirocrew-services.nix` | Revise | Keep the system-service direction, but remove broad `/home/orre` access and the operator-agent socket relay. Limit writes to dedicated state/workspace paths and make required-service failures explicit. |
| `nixos/kirocrew-sops.nix` | Revert | Remove the unwired age/Git-key draft. Design narrowly scoped repository credentials after the service identity and workspace layout are proven. |
| `nixos/kirocrew.nix` | Revert | Remove activation-time `curl | sh` installation. Package and pin KiroCrew declaratively as part of the AMI phase. |
| `nixos/kirocrew_ec2/launcher.py` | Revise | Preserve only independently valid defect fixes in separate commits: accurate service detection, Pasta failure reporting, CRG daemon supervision, and loopback/SSM portal behavior. Do not expand credential forwarding or custom AWS lifecycle scope. |
| `nixos/kirocrew_ec2/models.py` | Revert | Remove operator-agent forwarding state added for the rejected credential bridge. |
| `nixos/kirocrew_ec2/runtime.py` | Revert | Remove the SSH-agent forwarding transport added for the rejected credential bridge. |
| `security.nix` | Revert | Restore the prior workstation 1Password-agent permissions; do not weaken local socket access for EC2 migration. |
| `nixos/old-field-map-redshift.json` | Revert / exclude | Unrelated untracked data; keep it outside this KiroCrew change and decide its repository location separately. |
| `nixos/old-table-map-redshift.json` | Revert / exclude | Unrelated untracked data; keep it outside this KiroCrew change and decide its repository location separately. |
| `nixos/users_approved.tsv` | Revert / exclude | Unrelated potentially sensitive user data; do not include it in this repository change. |

Phase 0 is complete only after the dispositions above are implemented, the resulting diff is reviewed again, and the documented static checks pass. Runtime sandbox, reboot, restore, and service-health criteria remain unverified and belong to their respective phases.

## Objective

Build a persistent, recoverable NixOS development workspace for KiroCrew and normal agent-assisted development. The workspace should support repository editing, builds, tests, Code Review Graph, Pasta, and controlled writes to the canonical Obsidian vault without treating ordinary agent workloads as intentionally hostile code.

The design uses KiroCrew's built-in AWS lifecycle rather than maintaining a second EC2 lifecycle implementation. KiroCrew's strict sandbox, Unix identities, systemd hardening, narrow network access, versioned backups, and explicit write interfaces provide defense in depth. Disposable runners remain an optional escalation path for exceptional workloads such as privileged container builds or untrusted third-party code.

## Scope

### In scope

- A persistent NixOS EC2 workspace.
- KiroCrew's built-in `kirocrew cloud` lifecycle extended to accept a NixOS AMI.
- KiroCrew gateway and normal development workloads on the same host under a dedicated unprivileged identity.
- KiroCrew strict sandbox mode.
- Pasta as a hardened system service.
- Controlled read and write access to the Obsidian vault.
- Persistent, bounded development caches.
- SSM access and optional narrowly granted Tailscale access.
- Backup, restore, audit, monitoring, and deterministic rebuild procedures.
- Optional disposable runners for exceptional tasks.

### Out of scope for the initial implementation

- A disposable EC2 instance for every normal development task.
- A separate knowledge-plane machine.
- Direct public dashboard, SSH, or terminal ports.
- Fully autonomous production deployment or unrestricted Git pushes.
- Treating prompt rules, approval dialogs, or command deny-lists as the only security controls.

## Architecture decisions

### AD-1: Use one persistent NixOS workspace

Normal agent development does not justify a three-plane architecture. KiroCrew, development repositories, Code Review Graph, Pasta, and a controlled vault writer will run on one persistent NixOS instance with separate system identities and explicit filesystem permissions.

### AD-2: Use built-in Crew Cloud for AWS lifecycle

Extend KiroCrew's built-in CloudFormation template and `kirocrew cloud launch` command with a custom AMI parameter. Continue using its stack ownership, permissions boundary, SSM transport, encrypted EBS, source handling, start/stop, status, and destroy behavior.

Retire the custom Python `launch-ec2` lifecycle implementation after migration. Retain reusable NixOS modules and the AMI build pipeline.

### AD-3: Enable strict isolation

Configure:

```bash
kirocrew config set agent.sandbox strict
```

Strict isolation is defense in depth for normal development agents. It complements Unix permissions and systemd hardening; it does not replace them.

The implementation must prove that Linux user and mount namespaces work on the selected NixOS AMI. Cloud mode must fail closed if strict sandbox startup fails.

### AD-4: Separate identities by responsibility

Use these system identities:

| Identity | Responsibility | Privilege |
|---|---|---|
| `admin` | Human administration through SSM or Tailscale SSH | Sudo allowed |
| `kirocrew` | Gateway, agent subprocesses, development workspaces | No sudo; no Docker group |
| `pasta` | Pasta daemon and index | Read vault; write Pasta state |
| `vault-writer` | Validated vault mutations | Write vault; no shell login |
| Optional `builder` | Explicit privileged or container builds | Isolated from KiroCrew credentials |

The gateway must not run as the human administrator. Docker group membership is treated as root-equivalent and is not granted to `kirocrew`.

### AD-5: Mediate vault writes

KiroCrew searches and reads vault content through Pasta and mutates notes through a narrow Vault Writer interface. Generic agent shell commands do not receive unrestricted write access to the vault tree.

The Vault Writer supports:

- `search`
- `read`
- `create`
- `update`
- `append`
- `move`
- `list`
- `trash`

Permanent deletion is a human operation. Updates use optimistic concurrency with an expected content revision. Writes are atomic and audited.

### AD-6: Keep reusable caches trusted and bounded

Use the persistent local Nix store and a signed private Nix binary cache. Keep user-level dependency and analysis caches on persistent storage with quotas and cleanup. Agent tasks may consume trusted caches and create local cache entries under the development identity.

If disposable runners are introduced later, their writable caches are not promoted automatically into caches trusted by future tasks.

### AD-7: Prefer private access paths

Use SSM as the initial administration and dashboard access path. Tailscale is optional and may be added only with exact grants and loopback publication through Tailscale Serve. The host firewall must not trust the entire `tailscale0` interface.

## Target layout

```text
NixOS EC2 workspace
├── admin
│   └── SSM/Tailscale administration and sudo
├── kirocrew
│   ├── KiroCrew gateway
│   ├── strict agent sandbox
│   ├── /srv/kirocrew/workspaces
│   └── bounded development caches
├── pasta
│   ├── Pasta daemon
│   ├── read access to vault
│   └── /var/lib/pasta index state
├── vault-writer
│   ├── validated note mutation interface
│   └── write access to vault
├── backup service
│   └── versioned off-host backup
└── monitoring
    └── service, backup, disk, cache, and audit signals
```

## Storage design

### Root volume

- Encrypted gp3.
- Rebuildable from the promoted NixOS AMI.
- Backed up while the persistent control-plane state remains on it.

### Development workspaces

Use:

```text
/srv/kirocrew/workspaces/<repository>
```

The `kirocrew` identity owns these workspaces. Repository credentials are narrowly scoped per repository where autonomous fetch or push is required. Protected branches remain enforced by the forge.

### Vault

Prefer a local filesystem with predictable locking and atomic rename semantics:

```text
/var/lib/readpeak-vault
```

A dedicated synchronization or backup service writes versioned off-host copies. The design must not assume that Mountpoint for Amazon S3 provides full POSIX rename, locking, or concurrency semantics.

If S3 remains the primary store, implement conditional object writes and version-aware conflict handling through the Vault Writer instead of relying on a broadly writable FUSE mount.

### Pasta state

Use:

```text
/var/lib/pasta
```

The index is encrypted, backed up, and rebuildable from the vault. It is not the only copy of valuable information.

## Vault Writer interface

### Read result

```json
{
  "path": "1. Projects/KiroCrew/Architecture.md",
  "revision": "sha256:...",
  "content": "..."
}
```

### Create request

```json
{
  "path": "1. Projects/KiroCrew/Architecture.md",
  "content": "...",
  "ifAbsent": true
}
```

### Update request

```json
{
  "path": "1. Projects/KiroCrew/Architecture.md",
  "expectedRevision": "sha256:...",
  "content": "..."
}
```

### Required behavior

- Accept vault-relative normalized paths only.
- Resolve paths and reject traversal or symlink escape.
- Restrict normal note writes to Markdown and approved attachment types.
- Block service state such as `.obsidian/`, `.git/`, `.lancedb/`, `.semantic_search/`, and Pasta index directories.
- Enforce note and attachment size limits.
- Perform temporary-file, flush, fsync, and atomic-rename writes on a compatible filesystem.
- Return `CONFLICT` when `expectedRevision` no longer matches.
- Move deletions into a timestamped agent trash location.
- Record actor, session, path, before revision, after revision, operation, and timestamp without recording full note contents.
- Notify Pasta asynchronously after commit; indexing failure must not roll back a committed note.

The final path policy must explicitly list which PARA locations are writable. It should be configuration, not hard-coded assumptions.

## Service hardening

### KiroCrew

- Run as `kirocrew` system user.
- Enable strict sandbox and verify namespace isolation.
- No sudo, wheel, Docker socket, or Docker group.
- No operator SSH keys, age key, or broad AWS/Git credentials.
- Writable paths limited to KiroCrew state, development workspaces, temporary files, and caches.
- Dashboard remains loopback-bound.
- Restart automatically and report health.

### Pasta

- Run as `pasta` system user.
- Read vault; write only `/var/lib/pasta` and temporary state.
- Use systemd protections including a private temporary directory, empty capability set, restricted address families, protected system paths, and explicit read/write paths.
- Bind to loopback or a Unix socket accessible to KiroCrew.
- Autostart after storage is ready.

### Vault Writer

- Run as `vault-writer` with no login shell.
- Accept requests only from KiroCrew through a Unix socket or loopback-authenticated channel.
- Write only the vault and its own small transaction/audit state.
- Apply path, revision, size, and operation policy at the interface.

## Networking

### Required baseline

- No public inbound security-group rules.
- Dashboard and administration over SSM.
- IMDSv2 required.
- Block the `kirocrew`, `pasta`, and `vault-writer` identities from IMDS at the host firewall.
- Keep instance-role permissions at the built-in Crew Cloud ceiling unless a reviewed requirement needs expansion.
- Log DNS and relevant outbound connection metadata without logging secrets.

### Optional Tailscale

- Install only after the SSM baseline works.
- Keep services bound to loopback.
- Publish approved services through Tailscale Serve.
- Grant named human identities exact destination ports.
- Do not trust all traffic arriving on `tailscale0`.
- Prefer SSM or Tailscale SSH over an unauthenticated writable ttyd service.

## Caching

### Nix binary cache

Use the local Nix store plus a signed private binary cache. Only trusted CI builders may publish closures. Hosts receive read access and the public signing key.

### Persistent development caches

Suggested locations:

```text
/var/cache/kirocrew/npm
/var/cache/kirocrew/pip
/var/cache/kirocrew/uv
/var/cache/kirocrew/cargo
/var/cache/kirocrew/code-review-graph
```

Each cache has:

- Explicit ownership.
- Disk quota or maximum size.
- Last-access-based cleanup.
- Metrics for size, hit rate where available, and cleanup failures.

### Code Review Graph

- Install once through the NixOS image or controlled service update.
- Build a graph only when a repository lacks one.
- Update existing graphs incrementally.
- Register every repository idempotently.
- Ensure the daemon is running on every service start, even when no graph was newly built.

### Pasta cache/index

- Persist on encrypted storage.
- Invalidate by document revision where supported.
- Snapshot regularly.
- Track current vault revision versus indexed revision.

## AMI and lifecycle management

### Nix owns machine contents

The flake produces a versioned control/workspace AMI. CI evaluates and builds the configuration, launches a smoke-test instance, verifies services and sandbox behavior, and promotes the resulting AMI ID.

Publish promoted image IDs through SSM Parameter Store, for example:

```text
/kirocrew/images/workspace/arm64/candidate
/kirocrew/images/workspace/arm64/stable
```

### Crew Cloud owns AWS lifecycle

Add custom AMI support to KiroCrew's built-in template and launch command. The preferred interface is additive:

```bash
kirocrew cloud launch --ami-id <nixos-ami-id> --subnet <subnet-id>
```

When `--ami-id` is absent, existing Amazon Linux behavior remains unchanged. When present, the template skips the Amazon Linux bootstrap and expects the AMI to provide a healthy KiroCrew service.

### Update and rollback

1. Build and test a candidate AMI.
2. Promote it to the candidate parameter.
3. Launch a canary workspace.
4. Validate KiroCrew, strict sandbox, Pasta, Vault Writer, caching, backup, and access paths.
5. Promote to stable.
6. Replace or migrate the persistent instance during a controlled window.
7. Roll back by restoring the previous stable AMI and persistent data snapshot.

## Backup and recovery

Back up:

- Canonical vault with version history.
- Vault Writer audit state.
- KiroCrew state needed to restore conversations and configuration.
- Pasta index for fast recovery, while retaining the ability to rebuild it.
- Required repository working state that has not reached the forge.

Recovery tests must prove:

- A single overwritten note can be restored.
- A trashed directory can be restored.
- A synchronization conflict preserves both versions.
- A fresh NixOS instance can restore KiroCrew and Pasta operation.
- A backup failure triggers an actionable alert.

## Observability

Correlate agent sessions and vault mutations with a stable session identifier. Emit structured events without note contents or credentials.

Track:

- KiroCrew and Pasta availability.
- Strict sandbox startup failures.
- Vault write success, conflict, rejection, and indexing lag.
- Vault backup age and failures.
- Disk utilization and cache size.
- CRG daemon health and graph freshness.
- Unauthorized IMDS attempts.
- Tailscale or SSM access failures.

Page only for actionable conditions such as unavailable services, expired backups, filesystem exhaustion, repeated sandbox failure, or unrecoverable indexing lag.

## Implementation phases

### Phase 0: Freeze and reconcile the current changes

Review the existing uncommitted Nix and Python changes. Revert or redesign changes that conflict with this plan, including broad `tailscale0` trust, writable ttyd as `orre`, writable direct vault mounting, age-key copying, and duplicated lifecycle behavior.

Fix independently valid defects only after the target design is approved:

- Pasta source path mismatch (`/home/orre/pasta` versus `/home/orre/code/pasta`).
- CRG daemon startup when graphs already exist.
- Direct Tailscale dashboard URLs while the gateway remains loopback-bound.

**Acceptance criteria**

- Every current change is classified as retain, revise, or revert.
- No unreviewed secret or access expansion remains in the migration branch.
- Current known-good behavior remains recoverable.

**Verification**

- Review the complete Git diff.
- Run Python compilation/checks.
- Evaluate the NixOS configuration.
- Record any validation that cannot run.

### Phase 1: Prove strict sandboxing on NixOS

Create the dedicated `kirocrew` identity and make strict sandbox mode work on the NixOS AMI before moving vault or Pasta responsibilities.

**Acceptance criteria**

- KiroCrew reports strict mode active.
- Agent subprocesses cannot read administrator, AWS, SSH, age, Docker, or Kiro credential paths.
- The agent can edit and test an approved development workspace.
- A sandbox initialization failure prevents cloud-mode agent execution.
- `kirocrew` has no sudo or Docker access.

**Verification**

- Run positive workspace read/write/build tests.
- Run negative credential-path, home-path, IMDS, sudo, and Docker tests.
- Reboot and repeat the checks.

### Phase 2: Harden and package the workspace AMI

Move KiroCrew and common development tooling into the NixOS image. Add service hardening, persistent cache directories, quotas, SSM, and monitoring.

**Acceptance criteria**

- A clean AMI boots to a healthy KiroCrew gateway without imperative installation.
- Dashboard access works through SSM with no inbound rule.
- Cache directories have correct ownership and enforced size policy.
- Reboot preserves expected workspace and cache state.

**Verification**

- Build the AMI from a clean checkout.
- Launch a smoke-test instance.
- Validate services, firewall, users, mounts, and disk policies.

### Phase 3: Add custom NixOS AMI support to Crew Cloud

Extend the built-in KiroCrew CLI and CloudFormation template additively. Preserve the existing Amazon Linux path.

**Acceptance criteria**

- `kirocrew cloud launch --ami-id ...` launches the approved NixOS image.
- Existing launches without `--ami-id` remain unchanged.
- Stack lifecycle, IAM boundary, SSM connection, start, stop, and destroy work.
- A failed NixOS health check rolls back cleanly unless explicitly retained for diagnosis.

**Verification**

- Run targeted KiroCrew cloud tests.
- Run `cfn-lint` against the template.
- Launch and destroy a test stack in a non-production AWS environment.

### Phase 4: Deploy Pasta as a hardened system service

Run Pasta as `pasta`, correct source/state locations, and ensure it starts independently of an interactive login.

**Acceptance criteria**

- Pasta autostarts after reboot.
- Pasta can read the vault and update its own index.
- Pasta cannot write vault notes, KiroCrew state, administrator files, or development repositories.
- KiroCrew can query Pasta through the approved local interface.
- Index lag and service health are observable.

**Verification**

- Run positive query/index tests.
- Run negative filesystem permission tests.
- Reboot and confirm recovery without launcher intervention.

### Phase 5: Implement controlled writable vault access

Implement the Vault Writer interface, path policy, optimistic concurrency, atomic writes, trash, audit events, and asynchronous Pasta reindex notification.

**Acceptance criteria**

- Agents can create, update, append, move, and trash approved notes.
- Concurrent updates return conflicts instead of overwriting changes.
- Paths outside configured writable locations are rejected.
- `.obsidian`, index, Git, and internal state paths are blocked.
- Every mutation has an audit event and recoverable prior version.
- Pasta eventually reflects each committed note revision.

**Verification**

- Test create, update, append, move, conflict, traversal, symlink escape, oversize, blocked path, trash, restore, and indexing-failure behavior.
- Restore an earlier note version from backup.

### Phase 6: Add trusted access and operational tooling

Optionally add Tailscale Serve and grants after SSM access is stable. Add a read-only platform status command or runbook covering KiroCrew, Pasta, vault, backups, caches, and CRG.

**Acceptance criteria**

- Only named human identities reach approved services.
- Services remain loopback-bound.
- No broad trusted Tailscale interface exists.
- Status output identifies service health, backup age, cache pressure, and index lag without exposing secrets.

**Verification**

- Test allowed and denied tailnet identities and ports.
- Confirm AWS security groups still have no public ingress.
- Exercise the access rollback procedure.

### Phase 7: Migrate and retire the custom launcher

Migrate state and repositories to the Crew Cloud-managed NixOS workspace. Retire duplicated EC2, IAM, security-group, key-pair, and local state management after restoration and rollback have been demonstrated.

**Acceptance criteria**

- Built-in Crew Cloud manages the active workspace lifecycle.
- Required KiroCrew state, repositories, Pasta index, and vault access are present.
- Backup and rollback have been tested.
- Custom launcher resources are removed without deleting shared or unrelated AWS resources.
- Reusable NixOS modules and AMI build definitions remain.

**Verification**

- Perform a migration rehearsal.
- Compare source and destination manifests and revisions.
- Stop the old instance before deletion and observe the replacement.
- Delete the old resources only after the acceptance window.

### Phase 8: Add optional disposable runners only when justified

Introduce runners for untrusted repositories, privileged container builds, clean-room reproducibility, or workloads requiring temporary instance sizes. Normal development remains on the persistent strict-sandboxed workspace.

**Decision gate**

Implement this phase only when measured workloads demonstrate a concrete isolation, privilege, reproducibility, or capacity requirement that the persistent workspace cannot satisfy safely.

## Global definition of done

The workspace is complete when:

- The built-in Crew Cloud lifecycle launches the promoted NixOS AMI.
- KiroCrew runs under a dedicated unprivileged identity with strict sandboxing verified.
- Normal agent development works in approved repositories.
- Pasta autostarts under its own identity and is queryable by KiroCrew.
- Agents can safely create and update approved vault notes through the Vault Writer.
- Conflicts, trash, audit, versioning, backup, and restore are proven.
- Dashboard and administration have no public inbound exposure.
- Tailscale, if enabled, uses Serve and narrow grants rather than broad interface trust.
- Caches are persistent, bounded, observable, and recoverable.
- CRG graphs update incrementally and the daemon is always supervised.
- A fresh instance can be built and restored from versioned configuration and backups.
- The custom Python EC2 launcher is retired without losing reusable NixOS configuration.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Strict namespace sandbox is incompatible with the NixOS AMI | High | Prove it in Phase 1; fail closed; keep SSM recovery access |
| Agent overwrites a vault change | High | Expected revisions, atomic writes, trash, versioning, restore tests |
| S3-backed mount violates filesystem assumptions | High | Prefer local filesystem plus sync; otherwise use version-aware S3 operations |
| Shared host allows accidental cross-repository access | Medium | Dedicated identity, workspace path policy, strict sandbox profiles |
| Docker grants root-equivalent access | High | Keep `kirocrew` out of Docker group; use rootless or optional isolated builder |
| Cache growth fills disk | Medium | Quotas, cleanup timers, disk alerts, separate cache paths |
| Cache or index corruption | Medium | Signed Nix cache, rebuildable dependency caches, Pasta snapshots and rebuild path |
| Built-in Crew Cloud diverges from the custom-AMI extension | Medium | Additive upstream-compatible change and targeted cloud tests |
| Tailscale exposes unintended services | High | Loopback binding, Serve, exact grants, no trusted interface |
| Backup exists but cannot restore | High | Scheduled restore drills and measurable backup age |

## Approval gates

Human approval is required before:

1. Changing IAM policies or permissions boundaries.
2. Deploying or replacing EC2 instances.
3. Changing VPC, security-group, endpoint, firewall, or Tailscale policy.
4. Moving or changing the canonical vault storage/synchronization mechanism.
5. Enabling autonomous Git push or deployment credentials.
6. Destroying the old workspace or custom-launcher resources.

## Immediate next step

Review and approve this plan, then execute Phase 0 as a read-only classification of the current diff. The first implementation work should be Phase 1: prove KiroCrew strict sandboxing under a dedicated unprivileged identity on NixOS before extending cloud lifecycle or writable vault behavior.
