{
  pkgs,
  lib,
  vault,
  extraPaths,
  remote ? "gdrive:pasta-export",
  rclone ? pkgs.rclone,
  # Where the list of last exported files is kept; relative paths resolve
  # inside the vault. null: $XDG_STATE_HOME/vault-drive-export at run time.
  stateDir ? null,
}:

# The export script, built from the vault path and the always-exported paths.
# vault-drive-export.nix installs it; the vault-drive-export-selection check
# builds it against a scratch vault.
pkgs.writeShellApplication {
  name = "vault-drive-export";
  runtimeInputs = [
    rclone
    pkgs.ripgrep
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
    pkgs.coreutils
  ];
  text = ''
    cd ${lib.escapeShellArg vault}
    ${
      if stateDir == null then
        ''state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/vault-drive-export"''
      else
        "state_dir=${lib.escapeShellArg stateDir}"
    }
    # The files the last successful run exported, one path per line.
    saved="$state_dir/exported"

    # A locked git-crypt checkout holds ciphertext: the selector would match
    # nothing and --delete-excluded would empty the Drive mirror. Without
    # Home.md the lock state is unknown, so fail closed.
    if [ ! -r Home.md ]; then
      echo "Home.md missing or unreadable; cannot tell if the vault is locked" >&2
      exit 1
    fi
    if head -c 9 Home.md | grep -q GITCRYPT; then
      echo "vault is git-crypt locked; skipping export" >&2
      exit 0
    fi

    files=$(mktemp)
    list=$(mktemp)
    trap 'rm -f "$files" "$list"' EXIT

    # rg exits 1 when it finds no files; anything above that is an error, and
    # a failed selection must never reach rclone with a partial list.
    rc=0
    rg --files --null --glob '*.md' --glob '!4. Archive/**' >"$files" || rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "listing vault notes failed (rg exit $rc)" >&2
      exit 1
    fi

    # Only the YAML frontmatter selects a note: the block between a `---` on
    # line 1 and the next `---`. Markers in the body do not count, and an
    # unclosed block selects nothing.
    # An awk or xargs failure stops the script here (errexit).
    # shellcheck disable=SC2016 # awk program, not shell
    xargs -0 --no-run-if-empty awk '
        FNR == 1 { fm = ($0 == "---"); hit = 0; next }
        fm && $0 == "---" { if (hit) print FILENAME; fm = 0; nextfile }
        fm && ($0 == "status: ready" || $0 == "cloud: true") { hit = 1 }
      ' <"$files" >"$list"
    # Extra paths alone never trigger a sync: test before appending them.
    # An empty selection never syncs (that would wipe the mirror); it only
    # deletes the files the last run exported, so un-sharing the last note
    # still removes it.
    if [ ! -s "$list" ]; then
      if [ ! -s "$saved" ]; then
        echo "no notes selected; leaving Drive mirror unchanged" >&2
        exit 0
      fi
      echo "no notes selected; deleting the previously exported files" >&2
      rclone delete ${lib.escapeShellArg remote} \
        --files-from-raw "$saved" --max-delete 50
      : >"$saved"
      exit 0
    fi
    extra=(${lib.escapeShellArgs extraPaths})
    for p in "''${extra[@]}"; do
      if [ -e "$p" ]; then
        printf '%s\n' "$p" >>"$list"
      else
        echo "extra path not found, skipping: $p" >&2
      fi
    done

    # --files-from-raw: a note named `#ideas.md` is a path, not a comment.
    rclone sync . ${lib.escapeShellArg remote} \
      --files-from-raw "$list" --delete-excluded --checksum --max-delete 50

    # Saved only after a successful sync (errexit stops a failed one above).
    mkdir -p "$state_dir"
    cp "$list" "$saved.tmp"
    mv "$saved.tmp" "$saved"
  '';
}
