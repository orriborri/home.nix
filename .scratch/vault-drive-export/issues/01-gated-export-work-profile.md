# 01: Gated export runs on the work profile only

**What to build:** Wire the vault → Drive export module into the work profile so the hourly service and timer exist only where KiroCrew runs as a workstation with ReadPeak enabled. The script declares every tool it calls (including grep) as a runtime input, and the rclone sync caps deletions with `--max-delete 50`. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] The export module is part of the workstation module set, next to the pasta service
- [x] The gate requires `kirocrew.enable`, `kirocrew.role == "workstation"` and `readpeak.enable`
- [x] grep is a declared runtime input of the export script
- [x] The rclone sync command includes `--files-from`, `--delete-excluded`, `--checksum` and `--max-delete 50`
- [x] A flake check asserts the service and timer exist on the `orre` profile and not on `orre-personal`, and that the rendered command contains the flags above
- [x] `nix flake check` passes (the pre-push gate)
