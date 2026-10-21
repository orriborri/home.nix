# Tests for kirocrew-checkout-update (nixos/kirocrew-checkout-update.nix):
# one managed checkout fast-forwarded from its mirror, where edits that
# `code-review-graph install` makes do not count as local work.
# Run by the checkout-update flake check with git and the script on PATH.
set -euo pipefail

export HOME=$PWD/home GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
git config --global init.defaultBranch master
# The script sets core.sharedRepository=group (setgid object dirs), which the
# Nix build sandbox refuses. Env config outranks repo config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.sharedRepository GIT_CONFIG_VALUE_0=false

fail() { echo "FAIL: $*" >&2; exit 1; }

# A mirror with one commit, a checkout of it, then a second upstream commit
# the checkout has not seen yet. $1 = fixture name.
setup() {
  local up=$PWD/$1/up
  git init -q "$up"
  printf 'node_modules/\n' > "$up/.gitignore"
  mkdir -p "$up/.kiro/settings"
  printf '{"mcpServers":{}}\n' > "$up/.kiro/settings/mcp.json"
  echo one > "$up/app.txt"
  git -C "$up" add -A && git -C "$up" commit -qm one
  git clone -q --bare "$up" "$PWD/$1/mirror"
  git clone -q "$PWD/$1/mirror" "$PWD/$1/co"
  echo two > "$up/app.txt"
  git -C "$up" commit -qam two
  git -C "$up" push -q "$PWD/$1/mirror" master
  co=$PWD/$1/co
  mirror=$PWD/$1/mirror
}

run() { set +e; kirocrew-checkout-update "$mirror" "$co"; rc=$?; set -e; }

# 1. clean checkout: fast-forwarded
setup clean
run
[ $rc = 0 ] || fail "clean: exit $rc"
[ "$(cat "$co/app.txt")" = two ] || fail "clean: not fast-forwarded"

# 2. crg's .gitignore block and an untracked .kiro: dropped / kept, updated
setup crg-gitignore
printf '\n# Added by code-review-graph\n.code-review-graph/\n' >> "$co/.gitignore"
mkdir -p "$co/.kiro/steering" && echo x > "$co/.kiro/steering/code-review-graph.md"
run
[ $rc = 0 ] || fail "crg-gitignore: exit $rc"
[ "$(cat "$co/app.txt")" = two ] || fail "crg-gitignore: not fast-forwarded"
[ "$(cat "$co/.gitignore")" = node_modules/ ] || fail "crg-gitignore: .gitignore not restored"
[ -f "$co/.kiro/steering/code-review-graph.md" ] || fail "crg-gitignore: untracked crg file removed"

# 3. crg's rewrite of a tracked .kiro/settings/mcp.json: survives the update
setup crg-mcp
printf '{"mcpServers":{"code-review-graph":{}}}\n' > "$co/.kiro/settings/mcp.json"
run
[ $rc = 0 ] || fail "crg-mcp: exit $rc"
[ "$(cat "$co/app.txt")" = two ] || fail "crg-mcp: not fast-forwarded"
grep -q code-review-graph "$co/.kiro/settings/mcp.json" || fail "crg-mcp: crg config lost"

# 4. a staged edit is real work: skipped (exit 3), nothing touched
setup staged
echo mine > "$co/app.txt" && git -C "$co" add app.txt
printf '\n# Added by code-review-graph\n.code-review-graph/\n' >> "$co/.gitignore"
run
[ $rc = 3 ] || fail "staged: exit $rc, want 3"
[ "$(cat "$co/app.txt")" = mine ] || fail "staged: edit lost"
grep -q code-review-graph "$co/.gitignore" || fail "staged: crg block removed from a skipped checkout"

# 5. any other .gitignore change is real work too
setup gitignore-mixed
printf '\n# Added by code-review-graph\n.code-review-graph/\ndist/\n' >> "$co/.gitignore"
run
[ $rc = 3 ] || fail "gitignore-mixed: exit $rc, want 3"
grep -q dist/ "$co/.gitignore" || fail "gitignore-mixed: edit lost"

# 6. an untracked file outside crg's paths is real work
setup untracked
echo notes > "$co/notes.txt"
run
[ $rc = 3 ] || fail "untracked: exit $rc, want 3"

echo "checkout-update: all cases pass"
