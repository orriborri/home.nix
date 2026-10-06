{ pkgs }:

# Prunes old KiroCrew release worktrees so the fixed-size root cannot fill.
#
# Usage: kirocrew-prune-releases RELEASES_DIR CURRENT PREVIOUS REPOSITORY
#   Keeps CURRENT and PREVIOUS (PREVIOUS may be empty: first release), plus any
#   `*.stale-*` directory modified in the last 7 days (moved aside by hand and
#   kept for inspection). Everything else under RELEASES_DIR is removed, then
#   `git worktree prune` in REPOSITORY drops the dangling worktree records.
pkgs.writeShellApplication {
  name = "kirocrew-prune-releases";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.git
  ];
  text = ''
    releases="$1"
    current="$2"
    previous="$3"
    repository="$4"

    [ -d "$releases" ] || exit 0
    find "$releases" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
      [ "$dir" = "$current" ] && continue
      [ -n "$previous" ] && [ "$dir" = "$previous" ] && continue
      case "$dir" in
        *.stale-*)
          [ -n "$(find "$dir" -maxdepth 0 -mtime -7)" ] && continue
          ;;
      esac
      echo "pruning old KiroCrew release $dir"
      rm -rf "$dir"
    done
    git -C "$repository" worktree prune
  '';
}
