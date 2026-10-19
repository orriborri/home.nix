# 03: First live sync

**What to build:** Prove the export end to end against real Google Drive and the Claude Drive connector. See `../spec.md`, Further Notes, and `docs/research/vault-drive-export.md`.

**Blocked by:** 01, 02

**Status:** ready-for-human

- [x] Pre-check: a hand-uploaded `.md` file in Drive is readable by a Claude scheduled task through the connector (if not, record the fallback format decision in the spec before continuing)
  - 2026-10-19: the Google Drive connector found `connector-test.md` (`text/markdown`) by title and full text and read it with `read_file_content`. Text came back intact but markdown-escaped (`\---`, `\#`, trailing double spaces). Not yet tried from a scheduled task.
- [x] `rclone config create gdrive drive scope=drive.file` done with the Readpeak Google account; if Workspace blocks rclone's client, use an own GCP OAuth client with an Internal consent screen
  - 2026-10-19: done with rclone's shared client_id (rclone warns it is being retired during 2026; move to an own client with an Internal consent screen).
- [x] Switched to the work profile; the export timer is active
- [x] One test note has `cloud: true`; running the service puts it in Drive's `pasta-export` folder, byte-identical
  - 2026-10-19: first run at 07:51 exported 3 existing `status: ready` meeting notes instead of a test note; `rclone check --checksum` found 0 differences. User confirmed the 3 belong there.
- [ ] Removing the marker and running again removes the note from Drive (to trash)
- [ ] A Claude scheduled task reads the exported note
