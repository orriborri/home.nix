# 03: First live sync

**What to build:** Prove the export end to end against real Google Drive and the Claude Drive connector. See `../spec.md`, Further Notes, and `docs/research/vault-drive-export.md`.

**Blocked by:** 01, 02

**Status:** ready-for-human

- [ ] Pre-check: a hand-uploaded `.md` file in Drive is readable by a Claude scheduled task through the connector (if not, record the fallback format decision in the spec before continuing)
- [ ] `rclone config create gdrive drive scope=drive.file` done with the Readpeak Google account; if Workspace blocks rclone's client, use an own GCP OAuth client with an Internal consent screen
- [ ] Switched to the work profile; the export timer is active
- [ ] One test note has `cloud: true`; running the service puts it in Drive's `pasta-export` folder, byte-identical
- [ ] Removing the marker and running again removes the note from Drive (to trash)
- [ ] A Claude scheduled task reads the exported note
