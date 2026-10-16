Status: ready-for-agent

# Spec: vault → Google Drive export for cloud scheduled tasks

## Problem Statement

LLM jobs that summarise the Readpeak vault (starting with the weekly summary that turns `status: ready` notes into a Google Doc) run on the laptop through KiroCrew. When the laptop is off, they don't run. Cloud scheduled tasks (Claude) could run them, and already reach Slack, Gmail, Linear, Calendar, GitLab and Drive through connectors, but they cannot read the vault: it is git-crypt encrypted, and the cloud must never hold the git-crypt key.

## Solution

The work laptop exports a small, opt-in, plaintext subset of the vault to a Google Drive folder, one way, every hour. Git stays the source of truth; the Drive folder is a disposable mirror that cloud tasks read through the Drive connector. Only notes that explicitly opt in (frontmatter `status: ready` or `cloud: true`, or a configured extra path) ever leave the machine. The export never runs on the personal profile, never runs against a locked vault, and never wipes the mirror because of an empty or broken selection.

## User Stories

1. As Oscar, I want cloud scheduled tasks to read selected vault notes, so that LLM jobs run while my laptop is off.
2. As Oscar, I want only notes I explicitly mark to be exported, so that the rest of the encrypted vault never leaves the machine.
3. As Oscar, I want to mark a note for export with `cloud: true` in its frontmatter, so that opting in is one line.
4. As Oscar, I want notes with frontmatter `status: ready` exported automatically, so that the weekly summary sees them without extra tagging.
5. As Oscar, I want a line `status: ready` or `cloud: true` in a note's body (outside frontmatter) to NOT export it, so that quoting the marker in prose cannot leak a note.
6. As Oscar, I want notes under `4. Archive/` never exported, so that archived material stays local even if it still carries a marker.
7. As Oscar, I want to add specific always-exported paths (e.g. a task list) in config, so that jobs needing a fixed file get it without frontmatter edits.
8. As Oscar, I want removing the marker from a note to remove it from Drive on the next run, so that un-sharing works.
9. As Oscar, I want deleted or renamed notes removed from Drive on the next run, so that the mirror does not accumulate stale copies.
10. As Oscar, I want the export to skip, not sync, when the vault checkout is git-crypt locked, so that ciphertext never replaces the mirror and the mirror is never emptied.
11. As Oscar, I want the export to skip when no notes are selected, so that a bad selection cannot empty the mirror.
12. As Oscar, I want a cap on how many files one run may delete, so that a selection bug cannot wipe a large mirror in one run.
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

## Implementation Decisions

- A new Home Manager module defines the export: a packaged shell script plus a systemd user oneshot service and an hourly timer with `Persistent=true`.
- Gate: enabled only when `kirocrew.enable`, `kirocrew.role == "workstation"` and `readpeak.enable` are all true. It is imported in the workstation module set next to the pasta service, so the personal profile never gets it.
- Transport: rclone, one-way laptop → Drive, `sync` with `--files-from <list> --delete-excluded --checksum --max-delete 50`. No bidirectional sync. The remote is named `gdrive`; the destination folder is `pasta-export`.
- Credentials: an rclone remote created interactively with `scope=drive.file`; the token lives in the user's rclone config, not in Nix or sops, because it rotates.
- Selection: a note is selected when its YAML frontmatter (the block between the first two `---` lines at the top of the file) contains `status: ready` or `cloud: true`. Body matches do not count. `4. Archive/` is excluded. A module-level `extraPaths` list (empty by default) is appended.
- Safety guards, in order: (1) vault locked (git-crypt header in a known file) → exit 0 without syncing; (2) empty selection → exit 0 without syncing; (3) `--max-delete` caps deletions; rclone's own behaviour skips deletions after any error, and Drive deletions go to trash.
- The script declares every tool it calls (rclone, ripgrep or equivalent, grep, sed, coreutils) as runtime inputs; it must not rely on the host PATH.
- Research backing these decisions: `docs/research/vault-drive-export.md`.

## Testing Decisions

- Good tests check external behaviour only: which units exist on which profile, and which files the script hands to rclone under which vault states. They do not assert script internals.
- Seam 1, rendered config: evaluate the work and personal Home Manager configurations; assert the service and timer exist only on the work profile, and that the rendered command includes `--files-from`, `--delete-excluded` and `--max-delete`. Prior art: the existing KiroCrew and pasta gating checks in the flake.
- Seam 2, script behaviour: build the script and run it in a scratch vault with a stub `rclone` on PATH that records its arguments and the file list. Cases: locked vault → no rclone call; no selected notes → no rclone call; frontmatter `status: ready` and `cloud: true` selected; the same markers in the body only → not selected; a marked note under `4. Archive/` → not selected; `extraPaths` entries included. Prior art: the `update-sh-*` flake checks, which stub commands in `$TMPDIR/bin`.
- Not tested automatically: the real Drive API and the Claude Drive connector.

## Out of Scope

- Write-back from the cloud into the vault (needs the full `drive` scope; cloud output stays as Google Docs for now).
- Choosing which other KiroCrew or LLM jobs move to the cloud.
- Creating the weekly-summary cloud scheduled task and retiring the matching KiroCrew cron job (follow-up after the first sync).
- Any change to pasta.

## Further Notes

- Manual pre-check before relying on the design: upload one `.md` file to Drive and confirm a Claude scheduled task can read it through the connector. The connector's help article does not list `.md` or `.txt`. If it fails, export `.txt` copies or Google Docs instead.
- If Workspace blocks rclone's default OAuth client, create a client in a GCP project with an Internal consent screen; an External app in Testing status gets refresh tokens that expire after 7 days.
- Re-authorising with a different OAuth client ID likely hides the old `pasta-export` folder from rclone and creates a second one; delete the old folder by hand.
- A draft module already exists (uncommitted) from the earlier handoff; it matches this spec except for the frontmatter-only selection, the `readpeak.enable` gate, the missing grep runtime input and `--max-delete`.
- Known limitation: removing the marker from the last exported note leaves it on Drive, because an empty selection skips the sync (story 11 wins over story 8); delete it by hand.
