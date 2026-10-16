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
    pkgs.gnused
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
    del=$(mktemp)
    keep=$(mktemp)
    tmp=""
    trap 'rm -f "$files" "$list" "$del" "$keep" "$tmp"' EXIT

    # save <file>: replace the saved list with <file>, atomically (a temp
    # file in the state dir renamed over it), so a crash never truncates it.
    save() {
      mkdir -p "$state_dir"
      tmp=$(mktemp "$state_dir/exported.XXXXXX")
      cat "$1" >"$tmp"
      mv "$tmp" "$saved"
      tmp=""
    }

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
      # A rebase, merge or cherry-pick (or a held index lock) can leave notes
      # un-marked for a moment; never delete from such a transient state.
      git_dir=.git
      if [ -f .git ]; then
        git_dir=$(sed -n 's/^gitdir: //p' .git)
      fi
      for op in index.lock rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
        if [ -e "$git_dir/$op" ]; then
          echo "git operation in progress ($op); leaving Drive mirror unchanged" >&2
          exit 0
        fi
      done
      # Delete only saved files still in the vault, i.e. explicitly
      # un-marked. A missing one stays on Drive and in the saved list, so a
      # later run deletes it if it comes back un-marked.
      while IFS= read -r p; do
        if [ -e "$p" ]; then
          printf '%s\n' "$p" >>"$del"
        else
          printf '%s\n' "$p" >>"$keep"
        fi
      done <"$saved"
      # Over the cap, rclone would delete part of the set and fail; refuse
      # up front so a mass un-marking needs a deliberate cleanup by hand.
      n=$(wc -l <"$del")
      if [ "$n" -gt 50 ]; then
        echo "no notes selected; refusing to delete $n files, over the cap of 50" >&2
        exit 1
      fi
      if [ -s "$del" ]; then
        echo "no notes selected; deleting the previously exported files" >&2
        rclone delete ${lib.escapeShellArg remote} \
          --files-from-raw "$del" --max-delete 50 --rmdirs
      fi
      save "$keep"
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

    # A failed or interrupted sync may upload part of the list, so record
    # the old and the new names first; an un-share can then delete either.
    if [ -e "$saved" ]; then
      sort -u "$saved" "$list" >"$files"
    else
      sort -u "$list" >"$files"
    fi
    save "$files"

    # --files-from-raw: a note named `#ideas.md` is a path, not a comment.
    rclone sync . ${lib.escapeShellArg remote} \
      --files-from-raw "$list" --delete-excluded --checksum --max-delete 50

    # After a successful sync the mirror is exactly the list (errexit stops
    # a failed one above).
    save "$list"
  '';
}
