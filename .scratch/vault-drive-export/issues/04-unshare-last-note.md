# 04: Un-sharing the last exported note removes it from Drive

**What to build:** When a clean selection comes back empty (vault unlocked, no selection errors) but the previous run exported notes, the export removes exactly those previously exported files from the Drive mirror and nothing else, then records the now-empty state. This closes the gap where story 8 (un-sharing removes the note) lost to story 11 (an empty selection never wipes the mirror). The export remembers what it last exported in a local state file under the user's XDG state directory, written only after a successful sync. See `../spec.md` (stories 8 and 11, and the known limitation in Further Notes).

**Blocked by:** None (can start immediately)

**Status:** done

- [x] After every successful sync, the list of exported files is saved to a state file outside the vault and outside Nix
- [x] Clean empty selection + non-empty saved list → rclone deletes only the files on the saved list (no `sync`), with `--max-delete 50`, then the saved list is emptied
- [x] Clean empty selection + empty or missing saved list → rclone is not called
- [x] Locked vault, missing reference file, or selection error → rclone is not called and the saved list is unchanged
- [x] A failed rclone run leaves the saved list unchanged
- [x] The known-limitation sentence in the spec's Further Notes is replaced by a short description of this behaviour
- [x] Each case above is covered in the `vault-drive-export-selection` check (stub rclone records the subcommand and file list)
- [x] `nix flake check` passes
