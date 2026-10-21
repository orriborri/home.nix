# 05: Ship skills to `claude-remote`

**What to build:** Install the skills this pipeline uses (the new `analyze-ticket`, `implement-ticket`, `address-mr-feedback`, plus `tdd` and `code-review`) into `claude-remote`'s Claude config from this repo, read-only like `/etc/claude-remote/CLAUDE.md`. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** in-progress (code done, not deployed)

- [x] Skills come from a pinned version (mattpocock rev in `config/repos.toml`)
- [x] `claude-remote` cannot edit them (read-only inside the unit; VM test)
- [ ] A session lists them

## Comments

**2026-10-21: mechanism done for `tdd` and `code-review`, not deployed.**

- `~/.claude/skills` → `/etc/claude-remote/skills` (tmpfiles `L+`, like
  CLAUDE.md). That is a store `linkFarm` whose entries point at
  `/var/lib/code/mattpocock-skills/skills/engineering/<name>`, the checkout
  repo-sync keeps at the rev pinned in `config/repos.toml`
  (`3cca18b`). No second pin to keep in step.
- Issues 06, 08 and 11 add `analyze-ticket`, `implement-ticket` and
  `address-mr-feedback` to the same list (from a directory in this repo).
- Tests: `ec2-claude-remote-uid` checks the link and both targets;
  `claude-remote-sandbox` reads `~/.claude/skills/tdd/SKILL.md` from inside
  the unit and fails to write it (`Read-only file system`).
- Refactor: path built with the same rule as `destinationFor` in
  `kirocrew-code.nix`; EC2 drvPath unchanged by that step.

Not verified:
- That Claude Code 2.1.296 lists skills reached through a symlinked
  `~/.claude/skills` and symlinked skill dirs. Check on the box after deploy
  (last checkbox).

Review notes:
- The uid owns `~/.claude`, so it can replace the `skills` symlink itself
  (same as CLAUDE.md today). tmpfiles puts it back at boot and on activation.
- Matt's `tdd` describes red → green; the mandatory refactor step lives in
  `implement-ticket` (issue 08).
