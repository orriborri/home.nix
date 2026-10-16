# Research: vault-drive-export (rclone -> Google Drive -> Claude connector)

Date: 2026-10-15. Scope: `vault-drive-export.nix`. Primary sources only; "unverified" marks claims no primary source settles.

## 1. rclone `drive.file` scope

- rclone "can read/view/modify only those files and folders it creates"; files uploaded by other means "will not be visible to rclone". https://rclone.org/drive/
- Google's definition: "Create new Drive files, or modify existing files, that you open with an app" (plus files shared via Picker). Nothing about inheritance through folders. https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- So: a `pasta-export` folder created by rclone works for sync/`--delete-excluded`, because every file inside was created by rclone. Files placed in that folder by another app (e.g. the Claude connector writing a file) are invisible to rclone listings, so they are neither synced nor deleted. That they are invisible *rather than* erroring is inferred from rclone's doc + Drive query semantics (rclone lists with `'<id>' in parents`, backend/drive/drive.go `list`); not tested.
- Caveat: if the rclone token/config is lost and recreated, Google ties drive.file grants to the OAuth client (project), not the token. Re-auth with the same client ID should still see old files; with a different client ID the old folder becomes invisible and rclone would create a second `pasta-export`. Unverified from a primary source.

## 2. `sync` + `--files-from` + `--delete-excluded`, `--checksum`

- `--files-from` overrides and cannot be combined with other filter flags; rclone still traverses the remote and treats the names "as a set of filters". https://rclone.org/filtering/
- `--delete-excluded`: "deletes any files on the destination which are excluded from the command" — i.e. every destination file not in the list (within rclone's visibility). Flagged "dangerous ... use with `--dry-run` and `-v` first". https://rclone.org/filtering/
- Missing names in the list: "Rclone commands do not error if any names in the `--files-from` file are missing from the source remote." https://rclone.org/filtering/ — so a stale path is simply not uploaded, and its old copy on Drive is deleted (it is in the list, but absent from source, so plain sync deletes it).
- Empty list: not documented. By the filter semantics an empty set excludes everything, so `--delete-excluded` would empty the mirror. The module's `[ -s "$list" ]` guard is therefore necessary. Unverified by test.
- Deletions are skipped if any error happened: "Files in the destination won't be deleted if there were any errors at any point" (overridable with `--ignore-errors`). https://rclone.org/commands/rclone_sync/
- Deletes go to Drive trash by default (`use_trash` default true). rclone source backend/drive/drive.go.
- `--max-delete N` aborts with a fatal error past N deletions. https://rclone.org/docs/ — cheap extra guard against a bad selector run.
- `--checksum`: compares hash and size instead of mtime. https://rclone.org/docs/ Drive supports MD5, SHA1, SHA256 (`Hashes()` in drive.go; https://rclone.org/drive/). rclone uses the first common hash with local, i.e. MD5 (hash set order); MD5 choice not stated in docs, inferred from source.

## 3. Workspace admin controls and own client ID

- Admins can search apps by client ID and set them Trusted/Limited/Specific data/Blocked, and can block all unconfigured third-party apps. https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data (formerly support.google.com/a/answer/7281227). So rclone's shared default client ID can be blocked.
- Same page: "Trust internal apps" grants API access to unconfigured internal apps (apps the org develops).
- rclone procedure (https://rclone.org/drive/ "Making your own client_id"): create a Cloud project, enable Drive API, configure consent screen (Get started), audience "External" (or "Internal", which "will restrict API use to Google Workspace users in your organisation"), add scope `https://www.googleapis.com/auth/drive` (for drive.file, add `.../auth/drive.file` instead — inferred), add yourself as test user, create OAuth client of type "Desktop app", pass `client_id`/`client_secret` to `rclone config`.
- Testing status: rclone docs say grants "will expire after a week"; Google: external-user-type apps in Testing get "a refresh token expiring in 7 days". https://developers.google.com/identity/protocols/oauth2 Google's page does not mention Internal apps here; Internal user type has no publishing status, so the 7-day expiry should not apply (inferred, not stated).
- Recommendation for a Workspace account: Internal app type + own client ID; the hourly timer would otherwise break weekly.

## 4. Claude Google Drive connector

- Help center: Claude can "Read Sheets, Slides, PDFs, images, and MS Office files"; text extraction only; files "must fit within the conversation's context window"; no byte size limit stated. https://support.claude.com/en/articles/10166901-using-the-google-drive-integration
- Plain `.md` / `text/markdown` / `text/plain` is not listed. **Unverified** whether the connector reads them. This is the main design risk: test once with a single uploaded `.md` before building on it. Fallback options if unsupported: upload as Google Docs via `--drive-import-formats md` (lossy conversion, see 5) or as `.txt` (also unverified).

## 5. Does Drive mangle `.md` on upload?

- rclone "will not convert any files by default" (`import_formats` default `""`). https://rclone.org/drive/, backend/drive/drive.go — so `.md` stays a binary blob, byte-identical.
- MIME type: rclone uses `mime.TypeByExtension` and falls back to `application/octet-stream` (fs/mimetype.go). Go has no built-in `.md` mapping; it reads `/usr/share/mime/globs2` and `/etc/mime.types`. On this Fedora host `/etc/mime.types` maps `md` to `text/markdown`, so uploads should get `text/markdown`. Under a systemd user service the same files are readable, so same result (inferred). Whether Drive overrides the declared MIME type is not documented.

## Design implications for the module

1. Keep the empty-list guard; add `--max-delete` (e.g. 50) as a second guard.
2. drive.file is safe for this layout: `--delete-excluded` cannot touch anything outside rclone-created files.
3. Use your own Internal OAuth client to avoid admin blocking and 7-day expiry.
4. Verify connector reads `text/markdown` before relying on it; this is undocumented.
