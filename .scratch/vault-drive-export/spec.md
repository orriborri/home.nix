Status: ready-for-agent

# Spec: vault → Google Drive export for cloud scheduled tasks

## Problem Statement

LLM jobs that summarise the Readpeak vault (starting with the weekly summary that turns `status: ready` notes into a Google Doc) run on the laptop through KiroCrew. When the laptop is off, they don't run. Cloud scheduled tasks (Claude) could run them, and already reach Slack, Gmail, Linear, Calendar, GitLab and Drive through connectors, but they cannot read the vault: it is git-crypt encrypted, and the cloud must never hold the git-crypt key.

## Solution

The work laptop mirrors the vault's files that git does not ignore (tracked and untracked, minus `.claude/`) in plaintext to the Google Drive folder `readpeakVault`, one way, every hour. Git stays the source of truth; the Drive folder is a disposable mirror that cloud tasks read through the Drive connector. The user decided (2026-10-19, ticket 05) that a full plaintext copy on their own Readpeak Drive is acceptable on the condition that it is not shared with anyone: before every sync a sharing guard reads the Drive permissions of the folder and everything in it, and refuses to upload or delete anything while any of them is shared beyond the owner. The export never runs on the personal profile, never runs against a locked vault or during a git operation, and caps how many files one run may delete.

The opt-in selection (frontmatter `status: ready` / `cloud: true`, `extraPaths`, the saved list and the un-share delete path; tickets 02 and 04) is superseded by ticket 05.

## User Stories

1. As Oscar, I want cloud scheduled tasks to read the whole vault, so that LLM jobs run while my laptop is off. (Ticket 05; was: selected notes.)
2. ~~As Oscar, I want only notes I explicitly mark to be exported.~~ Superseded by ticket 05: the whole vault is mirrored, guarded by story 26.
3. ~~As Oscar, I want to mark a note for export with `cloud: true` in its frontmatter.~~ Superseded by ticket 05.
4. ~~As Oscar, I want notes with frontmatter `status: ready` exported automatically.~~ Superseded by ticket 05.
5. ~~As Oscar, I want a marker in a note's body to NOT export it.~~ Superseded by ticket 05.
6. ~~As Oscar, I want notes under `4. Archive/` never exported, so that archived material stays local.~~ Superseded by the user decision of 2026-10-19: the archive is mirrored too.
7. ~~As Oscar, I want always-exported extra paths in config.~~ Superseded by ticket 05.
8. ~~As Oscar, I want removing the marker from a note to remove it from Drive on the next run.~~ Superseded by ticket 05.
9. As Oscar, I want deleted or renamed notes removed from Drive on the next run, so that the mirror does not accumulate stale copies.
10. As Oscar, I want the export to skip, not sync, when the vault checkout is git-crypt locked, so that ciphertext never replaces the mirror and the mirror is never emptied.
11. ~~As Oscar, I want the export to skip when no notes are selected.~~ Superseded by ticket 05; the git-operation skip and the deletion cap guard against a half-written tree instead.
12. As Oscar, I want a cap on how many files one run may delete (10% of the vault, at least 50), so that a bad tree state cannot wipe a large mirror in one run.
13. As Oscar, I want deletions to go to the Drive trash, so that a mistake is recoverable.
14. As Oscar, I want the export to run hourly and catch up after the laptop was off, so that the mirror is fresh when cloud tasks run.
15. As Oscar, I want the export only on the work profile (KiroCrew workstation with ReadPeak enabled), so that the personal laptop never exports work notes.
16. As Oscar, I want the Drive credentials kept out of the repo and out of Nix, so that a rotating OAuth token is never committed.
17. As Oscar, I want rclone limited to the files it created (`drive.file` scope), so that it cannot read or delete anything else in my Drive.
18. As Oscar, I want files that cloud tasks write into the export folder left untouched by the sync, so that cloud output is not deleted by the mirror.
19. As Oscar, I want a documented setup path if Workspace blocks rclone's default OAuth client, using an Internal consent screen, so that tokens do not expire every 7 days.
20. As Oscar, I want to run the export on demand and see its result in the journal, so that I can verify a change immediately.
21. As Oscar, I want exported files byte-identical to the vault notes, so that cloud tasks see exactly what I wrote.
22. As Oscar, I want a manual pre-check that the Drive connector can read a `.md` file, so that the design is not built on an unsupported format.
23. As Oscar, I want the export's selection and safety rules covered by flake checks, so that the pre-push gate catches regressions.
24. As a cloud scheduled task, I want a stable folder name on Drive, so that my prompt can reference it.
25. As a cloud scheduled task, I want plain markdown with the original relative paths, so that note links and structure stay meaningful.
26. As Oscar, I want the export to refuse to upload or delete anything while `readpeakVault` or any file or folder in it is shared with anyone but me (a user, group, domain or anyone with the link), so that the plaintext vault never reaches anyone else. (Ticket 05.)
27. As Oscar, I want the old `pasta-export` folder moved to the Drive trash once the full mirror has synced, so that no stale copy stays behind. (Ticket 05.)

## Implementation Decisions

- A new Home Manager module defines the export: a packaged shell script plus a systemd user oneshot service and an hourly timer with `Persistent=true`.
- Gate: enabled only when `kirocrew.enable`, `kirocrew.role == "workstation"` and `readpeak.enable` are all true. It is imported in the workstation module set next to the pasta service, so the personal profile never gets it.
- Transport: rclone, one-way laptop → Drive, `rclone sync . "gdrive:readpeakVault" --files-from-raw <list> --delete-excluded --checksum --max-delete <cap>`. No bidirectional sync. The remote is named `gdrive`; the destination folder is `readpeakVault` (ticket 05; was `pasta-export`).
- Credentials: an rclone remote created interactively with `scope=drive.file`; the token lives in the user's rclone config, not in Nix or sops, because it rotates.
- Selection (ticket 05, widened by the user decision of 2026-10-19): `git ls-files -z --cached --others --exclude-standard` (tracked files plus untracked files git does not ignore; the vault may be a worktree with a `.git` file), deduplicated, only files that exist in the tree, minus `.claude/` at any depth (tracked `.claude/settings.local.json` may hold tokens). The vault's `.gitignore` keeps `.git/`, `.lancedb/`, `.semantic_search/`, `.obsidian/`, `.sync-backups/`, `.history/`, `kiro-monitor/` and `.trash/` out; `4. Archive/` and `.llm-wiki/` are mirrored. This one list is both the upload list and the basis of the deletion count. The frontmatter selection, `extraPaths`, the saved list in `$XDG_STATE_HOME` and the un-share delete path are removed; the script keeps no state.
- Sharing guard (ticket 05): `rclone lsjson --dirs-only --metadata --drive-metadata-permissions read gdrive:` gives the folder's permissions (rclone reports them as a JSON string in `.Metadata.permissions`; `lsjson --stat` on the folder has no metadata), and `rclone lsjson -R --metadata --drive-metadata-permissions read "gdrive:readpeakVault"` gives every file's and subfolder's. Anything but exactly one permission with `role: owner`, `type: user`, including missing or unparsable permissions, fails the run with the offending paths on stderr, before any upload or delete. No folder yet (first run) passes; the sync creates it. drive.file means rclone sees only what it created, so files others put in the folder are neither checked nor synced.
- Safety guards, in order: (1) no readable `Home.md` → fail; vault locked (git-crypt header in `Home.md`) → exit 0 without syncing; (2) git operation in progress (`index.lock`, `rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD` in the git dir) → exit 0 without calling rclone; (3) any listed file starting with the git-crypt header (`\0GITCRYPT`) → refuse; (4) more than one `readpeakVault` folder in the Drive root → refuse; (5) sharing guard; (6) duplicate paths in the folder listing → refuse, telling the user to run `rclone dedupe gdrive:readpeakVault`; (7) deletion cap: 10% of the upload list, at least 50; the files on Drive missing from the upload list (those under `.claude/` or gitignored paths included) are counted from the guard's listing, and over the cap the run fails before syncing, since rclone's `--max-delete` (also passed) would delete up to the cap before failing; rclone skips deletions after any error, and Drive deletions go to trash.
- Migration (ticket 05): if the root listing shows a `pasta-export` folder, `rclone purge gdrive:pasta-export` moves it to the Drive trash after a successful sync, never after a failed one. A failed purge only warns on stderr; the run still succeeds and the next run retries it.
- Exit codes: refusals (ciphertext, duplicate folders or paths, sharing, deletion cap) exit 3, which the unit's `RestartPreventExitStatus=3` keeps systemd from retrying; real failures (offline, Drive errors, no `Home.md`) exit non-zero otherwise and retry under `Restart=on-failure`.
- The script declares every tool it calls (rclone, git, jq, grep, sed, coreutils) as runtime inputs; it must not rely on the host PATH.
- Research backing these decisions: `docs/research/vault-drive-export.md`.

## Testing Decisions

- Good tests check external behaviour only: which units exist on which profile, and which files the script hands to rclone under which vault states. They do not assert script internals.
- Seam 1, rendered config (`vault-drive-export-gated`): evaluate the work and personal Home Manager configurations; assert the service and timer exist only on the work profile, `Restart=on-failure`, `RestartPreventExitStatus=3`, and that the rendered script names `gdrive:readpeakVault`, `--drive-metadata-permissions read`, `--delete-excluded`, `--checksum`, `--max-delete`, `--files-from-raw`, `ls-files -z --cached --others --exclude-standard`, no rclone `--exclude*` flag, and has git, grep and jq on its PATH. Prior art: the existing KiroCrew and pasta gating checks in the flake.
- Seam 2, script behaviour (`vault-drive-export-behaviour`, was `vault-drive-export-selection`): build the script and run it in scratch vaults with a stub `rclone` that answers `lsjson` with canned permission listings and records every call. Cases: owner only → sync with the flags and an upload list of exactly the non-ignored files, tracked or untracked, `4. Archive/` and `.llm-wiki/` included (no gitignored files, no deleted tracked files, nothing under `.claude/` even where tracked); a worktree vault (`.git` file) → syncs, and skips during a git operation in its git dir; a ciphertext file, two `readpeakVault` folders, duplicate paths → exit 3, no rclone sync or delete; shared with a user, anyone with the link, a group or a domain, on the folder, a file or a subfolder → exit 3, no sync or purge; missing permissions → refuse; missing folder → sync; `pasta-export` present → purge after the sync, not after a failed one, and a failed purge leaves exit 0; cap 60 for 600 files with 60 vs 61 files gone, and 61 files under `.claude/` and a gitignored `.lancedb/` on Drive count as deletions; locked vault, no `Home.md` (non-zero, not 3) and a git operation in progress → no rclone call.
- Not tested automatically: the real Drive API and the Claude Drive connector.

## Out of Scope

- Write-back from the cloud into the vault (needs the full `drive` scope; cloud output stays as Google Docs for now).
- Choosing which other KiroCrew or LLM jobs move to the cloud.
- Creating the weekly-summary cloud scheduled task and retiring the matching KiroCrew cron job (follow-up after the first sync).
- Any change to pasta.

## Further Notes

- With the `drive.file` scope, rclone cannot see a `readpeakVault` folder created by hand in the Drive UI; it would create a second one beside it. Do not create the folder by hand: let the first export run create it. If two exist, the export refuses (exit 3) until the extra one is deleted.
- Everything git does not ignore is mirrored: the upload list is `git ls-files --cached --others --exclude-standard`, minus `.claude/` at any depth. A new note reaches Drive on the next run without being added to git; gitignored files (`.lancedb/`, `.history/`, `.obsidian/`, `.trash/` and the rest of the vault's `.gitignore`) never do. Anything that must stay local has to be gitignored (or live under `.claude/`). Files already on Drive that later become gitignored or move under `.claude/` are deleted from Drive and count against the deletion cap.
- Manual pre-check before relying on the design: upload one `.md` file to Drive and confirm a Claude scheduled task can read it through the connector. The connector's help article does not list `.md` or `.txt`. If it fails, export `.txt` copies or Google Docs instead.
- If Workspace blocks rclone's default OAuth client, create a client in a GCP project with an Internal consent screen; an External app in Testing status gets refresh tokens that expire after 7 days.
- Re-authorising with a different OAuth client ID likely hides the old `pasta-export` folder from rclone and creates a second one; delete the old folder by hand.
- A draft module already exists (uncommitted) from the earlier handoff; it matches this spec except for the frontmatter-only selection, the `readpeak.enable` gate, the missing grep runtime input and `--max-delete`.
- The two notes below describe the opt-in export of tickets 02 and 04, superseded by ticket 05; kept for history.
- Un-sharing the last exported note: the export keeps the list of exported files in `$XDG_STATE_HOME/vault-drive-export/exported` (fallback `~/.local/state`). Before each sync it records the saved names plus the new ones, and after a successful sync exactly the synced list, so a failed sync never loses a name. All writes to the list are atomic (a temp file in the state dir renamed over it). An empty selection still never syncs (story 11). When the vault is unlocked and the selection ran without errors, it does nothing while the vault's git dir shows an operation in progress (`index.lock`, `rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`); otherwise it runs `rclone delete --rmdirs --max-delete 50` on only the saved files that still exist in the vault (explicitly un-marked) and keeps the missing ones in the list, so a later run can still delete them if they come back un-marked (story 8). More than 50 files to delete fails the run with the count and the cap, without calling rclone. A failed rclone run leaves the list unchanged.
- Migration: the list exists only after the first successful run of this script, so a note un-shared before then is not cleaned up; delete it from Drive by hand.
