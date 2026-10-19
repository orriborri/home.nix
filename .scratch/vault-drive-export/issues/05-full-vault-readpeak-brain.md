# 05: Mirror the whole vault to "Readpeak Brain", only while it is unshared

**What to build:** The export mirrors the whole vault (not just opt-in notes) to a Drive folder named `Readpeak Brain`, so cloud tasks and the Drive connector can read everything. It refuses to upload anything while that folder or any file in it is shared with anyone but the owner. The opt-in frontmatter selection and the un-share path from tickets 02 and 04 are replaced by a plain mirror. See `../spec.md`; the user decided (2026-10-19) that a full plaintext copy on their own Readpeak Drive is acceptable on the condition that it is not shared with anyone.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] Remote destination is `gdrive:Readpeak Brain`; the vault is mirrored with `rclone sync`, excluding `.git/`, `.obsidian/`, `.trash/` and `4. Archive/`
- [x] Sharing guard: before syncing, the script reads Drive permissions for the folder and every file in it (`rclone lsjson --metadata --drive-metadata-permissions read`); any permission other than a single owner (user, group, domain or anyone/link) → exit non-zero with a clear stderr message, no upload, no delete
- [x] If the folder does not exist yet (first run), the guard passes and the sync creates it
- [x] The git-crypt lock check (fail closed) and the mid-git-operation skip are kept
- [x] Deletion cap scales with the mirror: `--max-delete` is 10% of the vault's file count (minimum 50); a run that would exceed it fails without deleting
- [x] The frontmatter selection, saved-list state and un-share delete path are removed, along with their check cases; the state file is no longer written
- [x] One-time migration: if `gdrive:pasta-export` exists, it is purged (to Drive trash) after a successful sync to `Readpeak Brain`
- [x] Checks: the stub rclone simulates permission listings (owner only / shared with a user / anyone-with-link / missing folder) and records sync arguments; the gated check asserts the new destination and flags
- [x] Spec updated: Solution, stories and decisions describe the full mirror and the sharing guard; opt-in stories marked superseded by this ticket
- [x] `nix flake check` passes
