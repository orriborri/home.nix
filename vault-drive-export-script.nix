{
  pkgs,
  lib,
  vault,
  rclone ? pkgs.rclone,
}:

# The export script, built from the vault path. vault-drive-export.nix
# installs it; the vault-drive-export-behaviour check builds it against a
# scratch vault and a stub rclone.
let
  drive = "gdrive:";
  folder = "readpeakVault";
  remote = drive + folder;
  # The opt-in export's folder; purged once the full mirror has synced.
  legacy = "pasta-export";
  # Never mirrored. Unanchored dirs match at any depth; find below prunes
  # the same set so the deletion count matches what rclone keeps.
  excludes = [
    ".git/**"
    ".obsidian/**"
    ".trash/**"
    "/4. Archive/**"
  ];
  excludeFlags = lib.concatMapStringsSep " " (p: "--exclude ${lib.escapeShellArg p}") excludes;
  # A listing's entries, as a JSON array on stdin → the paths of those whose
  # permissions are anything but a single owner user. Missing or unparsable
  # permissions count as shared (fail closed). rclone reports them as a JSON
  # string; an array is accepted too.
  sharedJq = ''
    def perms: .Metadata.permissions? | if type == "string" then (try fromjson catch null) else . end;
    def private: perms | type == "array" and length == 1 and .[0].role == "owner" and .[0].type == "user";
    .[] | select(private | not) | .Path
  '';
in
pkgs.writeShellApplication {
  name = "vault-drive-export";
  runtimeInputs = [
    rclone
    pkgs.jq
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.coreutils
  ];
  text = ''
    cd ${lib.escapeShellArg vault}

    # A locked git-crypt checkout holds ciphertext: syncing it would replace
    # the mirror with it. Without Home.md the lock state is unknown, so fail
    # closed.
    if [ ! -r Home.md ]; then
      echo "Home.md missing or unreadable; cannot tell if the vault is locked" >&2
      exit 1
    fi
    if head -c 9 Home.md | grep -q GITCRYPT; then
      echo "vault is git-crypt locked; skipping export" >&2
      exit 0
    fi

    # A rebase, merge or cherry-pick (or a held index lock) can leave the
    # tree half-written; never mirror (and delete from) such a state.
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

    root=$(mktemp)
    tree=$(mktemp)
    top=$(mktemp)
    shared=$(mktemp)
    here=$(mktemp)
    there=$(mktemp)
    trap 'rm -f "$root" "$top" "$tree" "$shared" "$here" "$there"' EXIT

    # Sharing guard: the folder and everything in it must be private to the
    # owner. A listing error stops the script here (errexit), before any
    # upload or delete.
    rclone lsjson --dirs-only --metadata --drive-metadata-permissions read \
      ${lib.escapeShellArg drive} >"$root"
    folder=${lib.escapeShellArg folder}
    jq --arg f "$folder" '[.[] | select(.IsDir and .Name == $f)]' "$root" >"$top"
    jq -r ${lib.escapeShellArg sharedJq} "$top" >"$shared"
    if [ "$(jq length "$top")" -gt 0 ]; then
      rclone lsjson -R --metadata --drive-metadata-permissions read \
        ${lib.escapeShellArg remote} >"$tree"
      jq -r ${lib.escapeShellArg sharedJq} "$tree" >>"$shared"
    else
      # First run: no folder yet; the sync creates it.
      echo '[]' >"$tree"
    fi

    if [ -s "$shared" ]; then
      {
        echo "\"$folder\" or files in it are shared beyond the owner (or their permissions are unknown); refusing to sync:"
        head -n 10 "$shared"
      } >&2
      exit 1
    fi

    # Deletion cap: 10% of the vault's files, at least 50. Count the files
    # on Drive that the sync would delete and refuse up front, since rclone
    # would delete part of them before hitting --max-delete.
    find . \( -type d \( -name .git -o -name .obsidian -o -name .trash -o -path './4. Archive' \) \) -prune \
      -o -type f -print | sed 's|^\./||' | LC_ALL=C sort -u >"$here"
    n=$(wc -l <"$here")
    cap=$((n / 10))
    if [ "$cap" -lt 50 ]; then
      cap=50
    fi
    jq -r '.[] | select(.IsDir | not) | .Path' "$tree" | LC_ALL=C sort -u >"$there"
    gone=$(LC_ALL=C comm -23 "$there" "$here" | wc -l)
    if [ "$gone" -gt "$cap" ]; then
      echo "refusing to delete $gone files from \"$folder\", over the cap of $cap" >&2
      exit 1
    fi

    rclone sync . ${lib.escapeShellArg remote} ${excludeFlags} \
      --delete-excluded --checksum --max-delete "$cap"

    # One-time migration: the opt-in export's folder goes to the Drive trash
    # once the full mirror has synced (errexit stops a failed sync above).
    if jq -e --arg f ${lib.escapeShellArg legacy} 'any(.[]; .IsDir and .Name == $f)' "$root" >/dev/null; then
      echo "purging the old ${legacy} folder" >&2
      rclone purge ${lib.escapeShellArg (drive + legacy)}
    fi
  '';
}
