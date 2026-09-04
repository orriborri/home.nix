#!/usr/bin/env bash
# vault-git-setup.sh — one-time, operator-run wizard.
#
# Turns the local Obsidian vault into a git-crypt-encrypted git repository and
# pushes the first ENCRYPTED commit to a private GitLab repo. It refuses to push
# unless it has verified, against the actual committed blob, that note content is
# ciphertext — so plaintext can never reach the remote by accident.
#
# Run on the WORKSTATION (where the vault and your credentials live):
#   bash nixos/vault-git-setup.sh
#
# Prerequisites (both provided by the Nix config once switched):
#   - git, git-crypt on PATH
# Nothing here touches the remote KiroCrew host; that cutover is a later step.

set -euo pipefail

VAULT="${VAULT_DIR:-$HOME/Obsidian/Readpeak}"
REMOTE_URL="${VAULT_REMOTE:-git@gitlab.com:orriborri/Vault.git}"
KEYFILE="${VAULT_KEYFILE:-$HOME/.vault-git-crypt.key}"
PROBE="$VAULT/.git-crypt-encryption-probe.md"

TOTAL=8
step() { printf '\n\033[1m[%d/%d] %s\033[0m\n' "$1" "$TOTAL" "$2"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$1"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
confirm() {
  local reply
  read -r -p "  $1 [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ── Preflight ────────────────────────────────────────────────────────────────
command -v git >/dev/null || die "git is not on PATH"
command -v git-crypt >/dev/null || die "git-crypt is not on PATH (run home-manager switch first)"
[[ -d "$VAULT" ]] || die "Vault directory not found: $VAULT"
cd "$VAULT"

if [[ -d .git ]]; then
  die "$VAULT is already a git repository. This wizard is for first-time setup only."
fi

printf '\n\033[1mVault git-crypt setup\033[0m\n'
info "Vault:  $VAULT"
info "Remote: $REMOTE_URL"
info "Key:    $KEYFILE (you will copy this into 1Password)"
info "Everything committed is encrypted; index/state dirs are excluded."
confirm "Proceed?" || die "Aborted by operator."

# ── 1. git init ────────────────────────────────────────────────────────────--
step 1 "Initializing git repository"
git init --initial-branch=main --object-format=sha1
info "Initialized on branch main."

# ── 2. Exclusions and encryption attributes ──────────────────────────────────
step 2 "Writing .gitignore and .gitattributes"
# Exclude local index/state — mirrors the current S3 sync filters plus .git.
cat > .gitignore <<'IGNORE'
/.git/
/.lancedb/
/.semantic_search/
/.obsidian/
/.sync-backups/
/.history/
/kiro-monitor/
/.trash/
IGNORE
# Encrypt EVERYTHING that gets committed. .gitattributes and .gitignore
# themselves must stay in the clear so git can read them.
cat > .gitattributes <<'ATTR'
* filter=git-crypt diff=git-crypt
.gitattributes !filter !diff
.gitignore !filter !diff
ATTR
info "Wrote .gitignore (exclusions) and .gitattributes (encrypt all else)."

# ── 3. git-crypt init (symmetric key) ─────────────────────────────────────────
step 3 "Initializing git-crypt (symmetric key mode)"
git-crypt init
info "git-crypt initialized; a symmetric key now lives in .git/git-crypt/."

# ── 4. Export the key and store it in 1Password (BEFORE any push) ─────────────
step 4 "Exporting the git-crypt key"
umask 077
git-crypt export-key "$KEYFILE"
chmod 600 "$KEYFILE"
# The remote (sops) expects the key base64-encoded as a text secret.
KEY_B64="${KEYFILE}.b64"
base64 -w0 "$KEYFILE" > "$KEY_B64"
chmod 600 "$KEY_B64"
warn "This key decrypts the entire vault. If it leaks, encryption is void."
warn "If it is lost, the vault is unrecoverable."
info "Store BOTH in 1Password (raw for you, base64 for the remote sops secret):"
info "  op document create \"$KEYFILE\" --title 'vault-git-crypt-key' --vault Readpeak"
info "  # base64 form for secrets.yaml is at: $KEY_B64"
info ""
info "Then add it to the remote secret store so KiroCrew can unlock the vault:"
info "  sops secrets/secrets.yaml   # add:  vault-git-crypt-key: <paste $KEY_B64 contents>"
confirm "Have you stored the key in 1Password?" || die "Store the key first, then re-run from a clean state."

# ── 5. Stage and commit ───────────────────────────────────────────────────────
step 5 "Creating the initial commit"
git add .
git commit -m "Initial commit"
info "Committed $(git ls-files | wc -l) files."

# ── 6. VERIFY encryption against the committed blob (the safety gate) ─────────
step 6 "Verifying committed content is encrypted"
# Pick a real note to probe; fall back to a temporary one if none exist yet.
probe_created=0
sample="$(git ls-files '*.md' | head -n1 || true)"
if [[ -z "$sample" ]]; then
  echo "git-crypt encryption probe $(date -u +%s)" > "$PROBE"
  git add "$PROBE"
  git commit -m "Add encryption probe"
  sample=".git-crypt-encryption-probe.md"
  probe_created=1
fi
info "Probing committed blob for: $sample"
# The blob stored in git must begin with the git-crypt magic header, NOT the
# plaintext. `git show HEAD:<path>` reads the raw committed object without the
# smudge filter, so this inspects what would actually be pushed.
blob="$(git show "HEAD:$sample" | head -c 16 | tr -d '\0')"
if printf '%s' "$blob" | grep -q 'GITCRYPT'; then
  info "✓ Committed blob is git-crypt ciphertext (starts with GITCRYPT marker)."
else
  # Clean up the probe before failing so re-runs start clean.
  die "Committed blob for $sample is NOT encrypted. Refusing to push. \
Check .gitattributes; do not push this repository."
fi
# git-crypt's own view of coverage.
info "git-crypt status (encrypted files):"
git-crypt status -e 2>/dev/null | sed 's/^/    /' | head -n 10 || true
if [[ "$probe_created" == "1" ]]; then
  git rm -q "$PROBE"
  git commit -q -m "Remove encryption probe"
  info "Removed the temporary encryption probe."
fi

# ── 7. Add the remote ─────────────────────────────────────────────────────────
step 7 "Adding the remote"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi
info "origin = $REMOTE_URL"

# ── 8. Push (only reached if verification passed) ─────────────────────────────
step 8 "Pushing the first encrypted commit"
warn "This uploads the vault to the remote. Content is encrypted; filenames and"
warn "the directory structure are NOT (git-crypt encrypts file contents only)."
confirm "Push to $REMOTE_URL now?" || {
  info "Skipped push. When ready: git -C \"$VAULT\" push --set-upstream origin main"
  exit 0
}
git push --set-upstream origin main
printf '\n\033[1m✓ Vault is now an encrypted git repository and pushed.\033[0m\n'
info "Verify on GitLab: open a .md file in the web UI — it must look like binary/ciphertext."
info "Next: unlock it elsewhere with  git-crypt unlock \"$KEYFILE\"  after cloning."
