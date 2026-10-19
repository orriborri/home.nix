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
  # Never mirrored, even where tracked or not gitignored: .claude at any
  # depth (settings.local.json may hold tokens). An ERE over the
  # vault-relative path.
  skip = "(^|/)[.]claude/";
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
    pkgs.git
    pkgs.jq
    pkgs.gnugrep
    pkgs.gnused
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

    # Exit 3 marks a refusal: a retry cannot help, so the unit does not
    # restart on it (RestartPreventExitStatus=3). Real failures exit 1.
    refuse() {
      echo "$1" >&2
      exit 3
    }

    # The upload list, the one source of truth for what the mirror holds:
    # the files git does not ignore (tracked, and untracked but not
    # gitignored) present in the tree, minus .claude. Gitignored files
    # (.lancedb, .history, .obsidian and other indexes or caches) stay local.
    git ls-files -z --cached --others --exclude-standard | { grep -zvE ${lib.escapeShellArg skip} || [ "$?" -eq 1 ]; } \
      | while IFS= read -r -d "" p; do
        if [ -f "$p" ]; then printf '%s\n' "$p"; fi
      done | LC_ALL=C sort -u >"$here"

    # A tracked file still in git-crypt ciphertext (its smudge filter did not
    # run) must never replace the plaintext copy on Drive.
    while IFS= read -r p; do
      if [ "$(head -c 9 "$p" | tail -c +2)" = GITCRYPT ]; then
        refuse "\"$p\" is git-crypt ciphertext; refusing to sync"
      fi
    done <"$here"

    # Sharing guard: the folder and everything in it must be private to the
    # owner. A listing error stops the script here (errexit), before any
    # upload or delete.
    rclone lsjson --dirs-only --metadata --drive-metadata-permissions read \
      ${lib.escapeShellArg drive} >"$root"
    folder=${lib.escapeShellArg folder}
    jq --arg f "$folder" '[.[] | select(.IsDir and .Name == $f)]' "$root" >"$top"
    if [ "$(jq length "$top")" -gt 1 ]; then
      refuse "Drive has more than one \"$folder\" folder; delete the extra one in the Drive UI"
    fi
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
      refuse "$(
        echo "\"$folder\" or files in it are shared beyond the owner (or their permissions are unknown); refusing to sync:"
        head -n 10 "$shared"
      )"
    fi

    # Drive allows two files at one path; rclone cannot mirror onto that.
    if [ -n "$(jq -r '.[].Path' "$tree" | LC_ALL=C sort | uniq -d)" ]; then
      refuse "\"$folder\" holds duplicate paths; run: rclone dedupe ${remote}"
    fi

    # Deletion cap: 10% of the mirrored files, at least 50. Count the files
    # on Drive missing from the upload list (the sync deletes them, those
    # under .claude or gitignored paths included) and refuse up front, since rclone
    # would delete part of them before hitting --max-delete.
    n=$(wc -l <"$here")
    cap=$((n / 10))
    if [ "$cap" -lt 50 ]; then
      cap=50
    fi
    jq -r '.[] | select(.IsDir | not) | .Path' "$tree" | LC_ALL=C sort -u >"$there"
    gone=$(LC_ALL=C comm -23 "$there" "$here" | wc -l)
    if [ "$gone" -gt "$cap" ]; then
      refuse "refusing to delete $gone files from \"$folder\", over the cap of $cap"
    fi

    rclone sync . ${lib.escapeShellArg remote} --files-from-raw "$here" \
      --delete-excluded --checksum --max-delete "$cap"

    # One-time migration: the opt-in export's folder goes to the Drive trash
    # once the full mirror has synced (errexit stops a failed sync above). A
    # failed purge only warns; the next run retries it.
    if jq -e --arg f ${lib.escapeShellArg legacy} 'any(.[]; .IsDir and .Name == $f)' "$root" >/dev/null; then
      echo "purging the old ${legacy} folder" >&2
      if ! rclone purge ${lib.escapeShellArg (drive + legacy)}; then
        echo "warning: could not purge the old ${legacy} folder; the next run retries" >&2
      fi
    fi
  '';
}
