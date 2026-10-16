# 02: Frontmatter-only selection, with a behaviour check

**What to build:** The export selects a note only when its YAML frontmatter (the block between the first two `---` lines at the top of the file) contains `status: ready` or `cloud: true`. The same markers in the note body do not select it. A flake check runs the built script against a scratch vault with a stub `rclone` that records the file list, proving the selection and safety rules. See `../spec.md`.

**Blocked by:** 01

**Status:** done

- [x] Locked vault (git-crypt header) → rclone is not called
- [x] No selected notes → rclone is not called
- [x] Frontmatter `status: ready` → note is in the list
- [x] Frontmatter `cloud: true` → note is in the list
- [x] Marker only in the body → note is not in the list
- [x] Marked note under `4. Archive/` → not in the list
- [x] `extraPaths` entries are in the list
- [x] The check follows the stub-command pattern of the existing `update-sh-*` checks
- [x] `nix flake check` passes
