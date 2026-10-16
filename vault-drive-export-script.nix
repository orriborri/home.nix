{
  pkgs,
  lib,
  vault,
  extraPaths,
  remote ? "gdrive:pasta-export",
  rclone ? pkgs.rclone,
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

    # A locked git-crypt checkout holds ciphertext: the selector would match
    # nothing and --delete-excluded would empty the Drive mirror.
    if head -c 9 Home.md | grep -q GITCRYPT; then
      echo "vault is git-crypt locked; skipping export" >&2
      exit 0
    fi

    list=$(mktemp)
    trap 'rm -f "$list"' EXIT

    # Only the YAML frontmatter selects a note: the block between a `---` on
    # line 1 and the next `---`. Markers in the body do not count.
    # shellcheck disable=SC2016 # awk program, not shell
    rg --files --null --glob '*.md' --glob '!4. Archive/**' \
      | xargs -0 --no-run-if-empty awk '
          FNR == 1 { fm = ($0 == "---"); next }
          fm && $0 == "---" { fm = 0; nextfile }
          fm && ($0 == "status: ready" || $0 == "cloud: true") { print FILENAME; fm = 0; nextfile }
        ' >"$list" || true
    ${lib.concatMapStrings (p: "echo ${lib.escapeShellArg p} >>\"$list\"\n") extraPaths}
    if [ ! -s "$list" ]; then
      echo "no notes selected; leaving Drive mirror unchanged" >&2
      exit 0
    fi

    rclone sync . ${lib.escapeShellArg remote} \
      --files-from "$list" --delete-excluded --checksum --max-delete 50
  '';
}
