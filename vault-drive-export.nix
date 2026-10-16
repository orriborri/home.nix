{
  config,
  lib,
  pkgs,
  ...
}:

# Home Manager module: one-way export of selected vault notes to Google Drive,
# so cloud scheduled tasks (Claude Cowork, Drive connector) can read them
# without the git-crypt key. Drive is a disposable mirror; git stays the
# source of truth.
#
# Selection is opt-in per note: frontmatter `status: ready` or `cloud: true`,
# plus the paths in `extraPaths`. Everything else never leaves the machine.
#
# One-time setup (interactive OAuth, token stays out of the repo):
#   rclone config create gdrive drive scope=drive.file
# drive.file limits rclone to files it created itself.
let
  cfg = config.kirocrew;
  enabled = cfg.enable && cfg.role == "workstation" && config.readpeak.enable;

  vault = "${config.home.homeDirectory}/Obsidian/Readpeak";
  remote = "gdrive:pasta-export";
  extraPaths = [
    # "Tasks/_Tasks.md"
  ];

  exportScript = pkgs.writeShellApplication {
    name = "vault-drive-export";
    runtimeInputs = [
      pkgs.rclone
      pkgs.ripgrep
      pkgs.gnugrep
      pkgs.gnused
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

      rg --files-with-matches --glob '*.md' --glob '!4. Archive/**' \
        -e '^status: ready$' -e '^cloud: true$' . \
        | sed 's|^\./||' >"$list" || true
      ${lib.concatMapStrings (p: "echo ${lib.escapeShellArg p} >>\"$list\"\n") extraPaths}
      if [ ! -s "$list" ]; then
        echo "no notes selected; leaving Drive mirror unchanged" >&2
        exit 0
      fi

      rclone sync . ${lib.escapeShellArg remote} \
        --files-from "$list" --delete-excluded --checksum --max-delete 50
    '';
  };
in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.rclone ];

    systemd.user.services.vault-drive-export = {
      Unit = {
        Description = "Export opt-in vault notes to Google Drive";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${exportScript}/bin/vault-drive-export";
      };
    };

    systemd.user.timers.vault-drive-export = {
      Unit.Description = "Hourly vault export to Google Drive";
      Timer = {
        OnCalendar = "hourly";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
