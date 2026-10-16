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

  exportScript = import ./vault-drive-export-script.nix {
    inherit
      pkgs
      lib
      vault
      extraPaths
      remote
      ;
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
