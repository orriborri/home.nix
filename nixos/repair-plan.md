# NixOS workspace repair plan

Date: 2026-09-10

Status: proposed implementation plan following the configuration review. The
user has selected removal of Tailscale. This document plans the remaining
repairs; it does not record implementation or deployment as complete.

## Scope and baseline

Prioritize repairs to the existing EC2 workspace without redesigning AWS
lifecycle management or replacing the current git-crypt vault workflow.
Keep the existing protected repository mirrors and managed skills integration.
Local VM parity is deferred and does not gate EC2 implementation or deployment.

The review established that both NixOS configurations evaluate and all 14
existing Python tests pass. It did not establish live EC2 behavior or fresh
machine readiness. Some failures may currently be masked by manual host state.

The older `kirocrew-development-workspace-plan.md` contains dated decisions
that differ from today's code, including S3 vault storage and optional
Tailscale. Preserve that history and add a dated pointer to this repair plan
when updating documentation. Do not treat this repair as a new storage
migration or implementation of the older Crew Cloud roadmap.

## Simplicity constraints

Keep one disposable EC2 workspace and one systemd service set. Use SSM port
forwarding for access, native KiroCrew snapshots plus a small S3 upload wrapper
for recovery, and a single GitLab service-account PAT for permitted code
repositories. Do not add a VPN, browser terminal, custom control plane, HA
system, or a new vault service. The vault continues its direct synchronization
path; code changes use branches and merge requests. EC2 never receives AWS
infrastructure credentials and never merges to protected branches.

Treat indexes, caches, and build outputs as disposable. Prefer Nix packaging for
the gateway and its supporting tools when the existing build inputs make that
practical. Keep the packaging boundary small and defer only components whose
packaging cost would materially complicate replacement.

## 1. Remove Tailscale and the administrator web terminal

Files: `kirocrew-ec2.nix`, `kirocrew-security.nix`,
`kirocrew_ec2/{launcher,runtime,models}.py`, and access documentation.

- Remove Tailscale discovery, reachability checks, direct URLs, and fallback
  messages. Remove helpers and constants made unused by those changes.
- Portal and Obsidian always use the existing SSM forwarding flow. Preserve
  reconnect behavior, loopback endpoints, and current application authentication.
- Preserve the portal's optional 1Password forwarding lifecycle; verify that
  closing the portal makes the forwarded agent unusable. Correct relay cleanup
  if the current path activation does not stop the relay on socket disappearance.
- Remove `ttyd-zellij`, its package if otherwise unused, and terminal URLs.
  Keep Zellij available over the existing SSH-over-SSM connection and
  `kirocrew-zellij` launcher.
- Retain the existing bootstrap SSH arrangement during this repair. Inspect
  security-group rules before making any claim that the live host has no
  public ingress. No replacement VPN or new inbound ports are needed.

Acceptance:

- Launcher tests exercise portal and Obsidian forwarding, reconnect, missing
  Session Manager plugin, cancellation, and optional agent-forward cleanup.
- Evaluated EC2 configuration has no Tailscale or ttyd service enabled.
- On the test host, port 7681 has no listener and service identities cannot
  obtain an administrator terminal. SSH/Zellij, portal, and Obsidian still work.

## 2. Make secret bootstrap work on a fresh host

Files: `kirocrew-sops.nix`, `kirocrew_ec2/launcher.py`, and bootstrap tests.

- Place the system sops age identity in a root-owned persistent directory
  outside the gateway's writable home, and point system sops-nix at that path.
  The exact path should be shared between bootstrap code and its tests.
- Bootstrap this root-owned directory and key before the first rebuild; do not
  depend on the `kirocrew` account already existing on the official AMI.
- Preserve the operator's separate Home Manager secret requirements. Check
  each required identity destination independently; an existing operator key
  must not cause the system-key bootstrap to return early.
- Use restrictive permissions and atomic installation. Preserve existing keys,
  reject invalid/conflicting state clearly, and never print key contents.
- Declare secret-dependent service ordering using the pinned sops-nix module's
  actual activation/unit behavior. Replace timing guesses where practical and
  report missing secrets explicitly.

Acceptance:

- Test absent keys, operator-only key, system-only key, both keys, failure while
  obtaining a key, and repeated bootstrap. Use dummy identities in tests.
- A fresh test host provisions the required secrets before dependent services
  start. Gateway and display users can read only their intended secret outputs,
  and cannot read the root-owned age identity.
- Existing installations migrate without deleting their old identity until
  successful decryption and rollback requirements have been verified.

## 3. Repair cross-user access without exposing private homes

Files: `kirocrew-security.nix`, `kirocrew-services.nix`,
`kirocrew-vault-git.nix`, and `kirocrew-obsidian-xpra.nix` as needed.

- Make the MCP executable reachable by `kirocrew`. The final packaged binaries
  in step 5 should live in the Nix store; any interim symlink must have a
  traversable target path.
- Grant narrowly scoped traversal to Pasta's shared index while keeping its
  remaining home private. A read-only systemd path does not grant Unix access.
- Normalize ownership, setgid directories, and intended read permissions after
  vault clone/unlock. Moving a temporary checkout does not apply the destination
  directory's group inheritance retroactively.
- Reconcile existing checkouts idempotently. Preserve the display user's note
  access and denial of Git metadata; avoid recursive permission changes that
  expose credentials or grant Pasta write access.
- Define inheritance for notes created by both KiroCrew and Obsidian, including
  atomic-save replacement files. Ensure the vault Git service can read and
  commit them and Pasta can index them.
- Order gateway MCP readiness after the required binary/index initialization,
  or demonstrate a tested application retry path.

Acceptance:

- Run permission tests as the actual service UIDs on an isolated EC2 test host
  under the generated service sandboxes, using fixture data rather than the
  production vault. This does not require repairing the local VM profile.
- `kirocrew` can execute kb-mcp and query the Pasta index; Pasta can read fresh
  and existing notes but cannot modify vault content.
- Notes created and replaced by either writer remain readable by the indexer
  and synchronizer. Obsidian cannot modify protected Git metadata.
- Unrelated service homes, credentials, and protected mirrors remain private.

## 4. Make vault synchronization retryable

File: `kirocrew-vault-git.nix`, with local-Git integration tests.

- Commit only when there are working-tree changes, but fetch/reconcile/push
  independently of whether a new commit was needed.
- Detect outgoing commits separately from uncommitted files. A failed push
  must be retried on the next timer run even when the checkout is clean.
- Apply incoming fast-forward updates when there are no local edits. Handle
  divergent commits conservatively; preserve local work and report conflicts.
- Use one lock across clone and sync operations. Detect an existing merge or
  rebase instead of interfering with manual recovery.
- Account for concurrent application writers: recheck state and fail safely
  rather than reset, clean, force-push, or assume a Git-service lock prevents
  Obsidian from editing files.
- Validate the tracked upstream and push destination instead of silently
  assuming every checkout has the intended branch.

Acceptance:

- Local bare-repository tests cover commit success followed by push failure,
  retry without another edit, remote-only updates, clean no-op, divergence,
  conflict recovery, missing upstream, and overlapping sync runs.
- A git-crypt fixture proves synchronized note content remains encrypted in
  the remote repository. Failed sync never discards notes or local commits.

Status (2026-09-11): implemented and verified at the evaluation/unit level;
live EC2 verification pending.

- Sync logic extracted from the inline shell into a tested script,
  `scripts/kirocrew_vault_sync.py`, invoked by a thin `vaultSync` wrapper in
  `kirocrew-vault-git.nix` (mirrors the existing skill-sync/pinned-repo
  pattern). Commit happens only on a dirty tree; fetch, reconcile, and push run
  every timer tick regardless, so a push that failed while the tree was dirty
  is retried on a later clean tree. Incoming history is fast-forwarded when
  clean and rebased when divergent; an unrebasable divergence aborts and
  preserves local commits. A single `fcntl` lock (shared path with the clone
  service) serializes overlapping runs, an in-progress merge/rebase is detected
  and left alone, and the tracked upstream is validated before any push
  (detached HEAD and missing upstream both refuse). The systemd unit/timer were
  renamed `kirocrew-vault-push` -> `kirocrew-vault-sync`.
- Verified: `tests/test_vault_sync.py` (10 local bare-repo cases: clean no-op,
  commit+push, incoming fast-forward, push-failure-then-clean-retry, divergence
  rebase, conflicting-divergence abort/preserve, missing upstream, in-progress
  rebase, overlapping lock, detached HEAD) plus the full 35-test suite pass.
  The `kirocrew-ec2` config evaluates to a system derivation, and both vault
  wrappers build on x86_64 (so `writeShellApplication`'s ShellCheck/`bash -n`
  gate passes and the embedded script path resolves).
- Not yet verified: an aarch64 build of the wrappers (no aarch64 builder was
  available in this environment) and any live-host behavior. A git-crypt
  fixture proving remote content stays encrypted is still outstanding — the
  sync script deliberately does not touch git-crypt (unlock lives in the clone
  service), so that acceptance item needs a separate fixture test against the
  clone/unlock path.

Files: a small snapshot/upload service and the EC2 IAM policy.

- Run the built-in `kirocrew snapshot` command on its normal schedule; do not
  reimplement or fork the snapshot format.
- Upload completed tarballs to a dedicated S3 prefix with a write-only role.
  The instance cannot read, delete, or alter earlier backups and cannot manage
  buckets, IAM, keys, or other AWS resources.
- Keep failed uploads locally and retry them. Delete a local snapshot only
  after the upload and checksum have been confirmed.
- Keep secrets out of snapshots. Restore is a human-invoked operation on a
  replacement host. S3 versioning, encryption, and retention are configured
  outside EC2.

Acceptance:

- Test successful upload, checksum mismatch, S3 outage, retry, and replacement
  restore using a disposable fixture state.
- Confirm the EC2 role cannot list, read, delete, or overwrite backup objects
  outside the intended write path.

## 6. Package application versions for replacement

Files: `kirocrew-services.nix`, `kirocrew-code.nix`, `packages/`, and shared
source-build configuration where required.

- First record the known-working deployed revisions without exposing runtime
  credentials. Select and verify immutable commits and source hashes; do not
  substitute an arbitrary latest release.
- Package the gateway, Pasta, and code-review-graph with Nix where their locked
  source revisions and build dependencies can be expressed cleanly. Reuse
  existing package and source-builder conventions instead of introducing a new
  packaging framework.
- Point services at immutable store executables and remove fetch/build/install
  work from service startup. Leave only mutable application data in state
  directories.
- If one component cannot yet be packaged without a disproportionate expansion
  of scope, pin its source revision and isolate that exception explicitly; do
  not let it block the rest of the replacement workflow.
- Keep the workstation workflow functional if shared builder code changes.
  An interim runtime version pin is useful but does not complete this step.
- Document application data compatibility separately from binary rollback.

Acceptance:

- Build on x86_64 and an available native/remote aarch64 builder.
- Restart with source registries unavailable and verify no build/download is
  required. An unchanged flake starts the same application code.
- Test switching between retained generations with disposable application data.
  Record any data migration that prevents safe rollback.

## 7. Documentation and deployment verification

- Rewrite `README.md` and `kirocrew.md` around the actual outputs, dedicated
  system services, git-crypt vault, secret bootstrap, and SSM access paths.
  Mark `configuration.nix` as an inactive legacy example.
- Add recovery instructions for failed vault sync, missing keys, Pasta access,
  application rollback, and tunnel failures. Link this plan from the older
  architecture document with the dated Tailscale decision.
- Run the Python suite, relevant formatting/lint checks, `nix flake check`,
  explicit evaluation of both AMI architectures, and
  `home-manager build --flake path:/home/orre/.config/home-manager#orre`.
  There is no `orre-minimal` output; do not target it.
- Validate fresh bootstrap, permissions, and service behavior on an isolated
  EC2 test host with dummy secrets and fixture repositories before production
  activation. Provisioning that host is a future deployment action. Prepare a
  scoped deployment artifact and inspect the production target's current
  generation, service state, filesystem permissions, and pending vault commits.
- Before activation, preserve a recoverable copy of mutable vault/application
  state, ACLs, and the old generation. Avoid a snapshot taken during a Git write.
- Following activation, verify services, timers, authenticated UI access,
  cross-user access denials, MCP queries, sync retries, and tunnel shutdown.
  Reboot and repeat the critical checks before declaring the repair complete.

## Delivery order

Implement steps 1–4 as small regression-test-first repairs. Complete the
bounded Nix packaging work next, then perform EC2 deployment verification.
Local VM parity is a separate backlog item. Update
the relevant runbook alongside each change. If Git metadata is available,
keep commits scoped to these steps and exclude unrelated workspace changes.

Implementation and live deployment are future actions; the current request is
to prepare this plan. Each completed step must record its checks and remaining
limitations, distinguishing evaluation, successful builds, isolated EC2 tests,
and production-host verification.

## Deferred: restore a functional local VM

Schedule separately when local VM support becomes a priority. The criteria
below apply only to that future work.

Files: `flake.nix`, `kirocrew-host.nix`, and a shared headless module if needed.

- Extract the common headless identities and service wiring from EC2-only
  imports, then compose VM, live EC2, and AMI outputs from it.
- Keep Amazon boot configuration, SSM, and cloud bootstrap in the EC2 host
  layer. Keep local VM credentials and forwarding confined to the VM layer.
- Provide a documented local fixture profile for vault, secrets, and sample
  repositories so VM smoke tests do not require production credentials.
- Confirm the headless Home Manager role disables duplicate user services
  only when the corresponding system services are supplied.

Acceptance:

- Evaluate all host/image outputs and build the VM.
- Boot it and verify one gateway service, Pasta/MCP access, fixture vault sync,
  and the documented dashboard tunnel. Test a second boot for idempotency.
