# ADR-002: KiroCrew-Managed Vault via git-crypt-Encrypted Git Repository

## Status

Accepted and **deployed** on 2026-09-04 to the EC2 host (`i-05d4aaf8ee73fc07f`).
Supersedes the vault-storage decision in
[ADR-001](001-kirocrew-remote-workspace.md) (read-only S3 mount). The vault is
now a git-crypt-encrypted git repository (`gitlab.com/orriborri/Vault`) that
KiroCrew clones, unlocks, edits, and pushes; the write→commit→push round-trip
was verified with the pushed blob confirmed as ciphertext.

Auth uses a GitLab **deploy token** over HTTPS (username `oauth2`, token +
git-crypt key provisioned as sops secrets to the `kirocrew` user). Two defects
were found and fixed during rollout: (1) the vault-clone unit had a bogus
`Requires=sops-nix.service` (that unit name does not exist in this sops-nix
version — secrets are placed during activation into `/run/secrets`), which
silently skipped the service; removed. (2) the push service was missing
`git-crypt` in its `runtimeInputs`, so `git add` failed the clean filter — this
failed closed (no plaintext pushed) and was fixed by adding `git-crypt`.

## Context

ADR-001 mounted the Obsidian vault read-only from S3 on the remote and kept the
workstation as the only writer. The operator then required the remote KiroCrew
agent to **manage** the vault — create and edit notes — not just read it.

A writable S3 mount was rejected: Mountpoint for Amazon S3 lacks atomic-rename
and locking semantics, and two independent writers (workstation rclone bisync +
remote) against the same objects can silently clobber notes. The vault also
contains sensitive content (meeting, people, and decision notes), so any hosted
store should not hold readable plaintext.

## Decision

Store the vault as a **git repository** whose file contents are encrypted with
**git-crypt**, and let KiroCrew own that repository end-to-end.

### Why git

- Atomic commits, history, and merge/rebase give real concurrency control —
  the property the S3 mount lacked. Multiple writers reconcile via git instead
  of overwriting.
- Every agent change is an auditable, revertible commit.
- Reuses existing machinery: the git SSH key, `known_hosts`, and the
  fetch/checkout patterns already deployed for code repos.

### Why git-crypt

- Transparent per-file encryption: plaintext in the working tree (so Obsidian,
  Pasta, and the agent work normally), ciphertext in the repository and on the
  remote host. Teammates with repo access and the hosting provider see only
  ciphertext.
- Symmetric-key mode is used (no GPG keyring exists on these hosts). The key is
  exported once and stored in 1Password; the remote receives it as a sops/age
  secret.

### Encryption scope

- Encrypt **everything committed** — notes and attachments — via
  `* filter=git-crypt diff=git-crypt`, with `.gitattributes` and `.gitignore`
  themselves in the clear.
- **Exclude from the repo** (not committed): `.git`, `.lancedb`,
  `.semantic_search`, `.obsidian`, `.sync-backups`, `.history`, `kiro-monitor`,
  `.trash` — indexes and local state, matching the former S3 sync filters.
- Filenames and directory structure are **not** encrypted (git-crypt encrypts
  file contents only). Do not put secrets in filenames or commit messages.

### Ownership model (Model 2 — KiroCrew owns the repo)

- The vault repo lives at `/var/lib/vault`, owned `kirocrew:vault-readers`
  (Pasta reads via the group).
- `kirocrew-vault-clone.service` clones `git@gitlab.com:orriborri/Vault.git`
  and unlocks it with the git-crypt key before the gateway starts.
- `kirocrew-vault-push.service` (with a 10-minute timer) commits the agent's
  edits and rebase-pushes them, integrating concurrent workstation commits.
- The gateway has read-write access to the vault working tree;
  `.git`/index/state remain read-only to the agent.

### Key provisioning

- System-level sops (`kirocrew-sops.nix`) decrypts with the `kirocrew` user's
  age key (`/var/lib/kirocrew/.config/sops/age/keys.txt`) and writes:
  - `git-ssh-key` → `/var/lib/kirocrew/secrets/git-ssh-key` (clone/push transport)
  - `vault-git-crypt-key` → `/var/lib/kirocrew/secrets/vault-git-crypt-key`
    (base64 of the git-crypt symmetric key; decoded at unlock time)
- `sops-nix.nixosModules.sops` is imported into the EC2 system and AMI outputs.

## Alternatives Considered

- **Writable S3 mount (whole vault or a notes prefix).** Rejected: no atomic
  rename/locking; two-writer corruption risk. A notes-prefix variant was
  prototyped and reverted in favor of git.
- **Keep workstation as sole writer.** Rejected: the operator explicitly wants
  the remote agent to manage the vault.
- **GPG-mode git-crypt.** Rejected for now: no GPG keyring exists on these
  hosts; symmetric key + sops/age matches existing infrastructure.
- **SOPS-encrypting each note.** Rejected: SOPS targets structured data;
  git-crypt is the natural fit for a markdown vault and is fully transparent.

## Consequences

### Positive

- The remote agent can create, edit, and delete notes with real version
  control and conflict handling.
- Vault contents are encrypted at rest on the provider and unreadable to
  teammates.
- Auditable history and easy revert of agent changes.
- Reuses existing git and sops/age infrastructure.

### Negative

- git-crypt files diff/merge as binary on any host without the key (both our
  hosts hold the key, so normal use is unaffected; CI and the provider web UI
  cannot edit encrypted files).
- The git-crypt key is now a critical secret: losing it makes the vault
  unrecoverable; leaking it voids encryption. It lives in 1Password and as a
  sops secret.
- Filenames/paths are not encrypted — a metadata leak accepted as low risk.
- The commit/push cadence (10 min) means agent edits reach the remote git
  history in batches, not instantly.

## Deployment Prerequisites (operator)

The live cutover must not run until all of these are done:

1. `home-manager switch` on the workstation so `git-crypt` is on PATH.
2. Create the **private** repo `git@gitlab.com:orriborri/Vault.git` under the
   personal namespace (not the `readpeak` group).
3. Run `nixos/vault-git-setup.sh` — it initializes git-crypt, verifies the
   committed blob is ciphertext (fail-closed), and pushes the first encrypted
   commit. Store the exported key in 1Password.
4. Add `vault-git-crypt-key` (base64) to `secrets/secrets.yaml`.
5. Bootstrap the `kirocrew` age key at
   `/var/lib/kirocrew/.config/sops/age/keys.txt` on the remote.
6. Ensure the `kirocrew` git SSH key has push access to the Vault repo.

On cutover, the removed `readpeak-vault-s3-mount` unit is stopped by activation
before `kirocrew-vault-clone` populates `/var/lib/vault`.

## Rollback

- Re-import `kirocrew-vault.nix` (read-only S3 mount) in place of
  `kirocrew-vault-git.nix` and rebuild; the S3 bucket remains the fallback copy.
- The NixOS generation rolls back service configuration; the encrypted git repo
  and the S3 bucket both persist independently.

## Verification (after deploy)

1. `kirocrew-vault-clone.service` active; `/var/lib/vault/.git` present and
   `git-crypt status` shows content decrypted in the working tree.
2. The gateway can read and write a note; `kirocrew-vault-push.service` commits
   and pushes it; the pushed blob on GitLab is ciphertext.
3. Concurrent workstation commit + remote push reconcile via rebase without
   data loss.
4. Reboot preserves clone, unlock, timer, and gateway access.

## References

- [`nixos/kirocrew-vault-git.nix`](../../nixos/kirocrew-vault-git.nix)
- [`nixos/kirocrew-sops.nix`](../../nixos/kirocrew-sops.nix)
- [`nixos/vault-git-setup.sh`](../../nixos/vault-git-setup.sh)
- [`nixos/kirocrew-vault.nix`](../../nixos/kirocrew-vault.nix) — retained S3-mount fallback
- [ADR-001](001-kirocrew-remote-workspace.md) — superseded vault-storage decision
