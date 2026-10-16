# Handoff: vault → Google Drive export for cloud scheduled tasks

Date: 2026-10-15

## Goal

Let cloud scheduled tasks (Claude Cowork) run the LLM jobs that KiroCrew runs on the laptop today, starting with the weekly summary that turns `status: ready` notes into a Google Doc. They need to run while the laptop is off.

## Constraints

- The vault (`~/Obsidian/Readpeak`) is encrypted in git with git-crypt (`.gitattributes`: `* filter=git-crypt`). The cloud must not hold the git-crypt key.
- pasta (`~/code/pasta`, `pasta-service.nix`) does the mechanical sync and stays local. It is not modified.
- Cloud tasks already reach Slack, Gmail, Linear, Calendar, GitLab and Drive through connectors. They only need vault content.

## Decision

Export a one-way, opt-in, plaintext subset of the vault to Drive. Git stays the source of truth, and the Drive folder is a disposable mirror.

- **Tool:** rclone (Google has no Drive client for Linux).
- **Direction:** Fedora → Drive only, with no bidirectional sync.
- **Scope:** OAuth scope `drive.file`, so rclone sees only the files it creates.

## Done

- Wrote `~/.config/home-manager/vault-drive-export.nix`. `nix-instantiate --parse` passes. It has not been built or switched.
  - It selects notes with frontmatter `status: ready` or `cloud: true`, excluding `4. Archive/`, plus the `extraPaths` list (empty by default).
  - It runs `rclone sync . gdrive:pasta-export --files-from <list> --delete-excluded --checksum`.
  - It skips the sync if the vault is git-crypt locked (`Home.md` starts with `GITCRYPT`) or if no notes are selected. Either case would otherwise empty the mirror.
  - It runs from a systemd user timer, hourly with `Persistent=true`, gated on `kirocrew.enable && role == "workstation"`, the same gate as pasta.
  - The rclone token lives in `~/.config/rclone/rclone.conf` and is not managed by Nix or sops, because the token rotates.

## Next steps (Oscar)

1. Import `./vault-drive-export.nix` where `pasta-service.nix` is imported (in `flake.nix`).
2. Run `home-manager switch --flake .#orre`. `writeShellApplication` runs shellcheck at build time.
3. Run `rclone config create gdrive drive scope=drive.file` and sign in with the Readpeak Google account. If Workspace blocks rclone's OAuth client, create your own client in a GCP project.
4. Add `cloud: true` to one test note, then run `systemctl --user start vault-drive-export` and check `journalctl --user -u vault-drive-export`.

## Next steps (Claude, after the first sync)

1. Check that the Drive connector reads a raw `.md` file from `pasta-export` cleanly. If it doesn't, change the export to `.txt` or Google Docs.
2. Create the weekly summary as a cloud scheduled task that reads `pasta-export` and writes a Google Doc.
3. Retire the matching KiroCrew cron job once the scheduled task has produced matching output.

## Open questions

- **Write-back into the vault:** this needs the `drive` scope instead of `drive.file`, because rclone can't see files that the connector creates. It's deferred, and cloud output stays as Google Docs for now.
- **Which jobs move next:** decide which other KiroCrew or LLM jobs to move to the cloud and which need extra paths in `extraPaths`, such as `Tasks/_Tasks.md`.
