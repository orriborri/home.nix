# 02: Frontmatter-only selection, with a behaviour check

**What to build:** The export selects a note only when its YAML frontmatter (the block between the first two `---` lines at the top of the file) contains `status: ready` or `cloud: true`. The same markers in the note body do not select it. A flake check runs the built script against a scratch vault with a stub `rclone` that records the file list, proving the selection and safety rules. See `../spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Locked vault (git-crypt header) → rclone is not called
- [ ] No selected notes → rclone is not called
- [ ] Frontmatter `status: ready` → note is in the list
- [ ] Frontmatter `cloud: true` → note is in the list
- [ ] Marker only in the body → note is not in the list
- [ ] Marked note under `4. Archive/` → not in the list
- [ ] `extraPaths` entries are in the list
- [ ] The check follows the stub-command pattern of the existing `update-sh-*` checks
- [ ] `nix flake check` passes
