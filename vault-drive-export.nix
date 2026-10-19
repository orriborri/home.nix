{
  config,
  lib,
  pkgs,
  ...
}:

# Home Manager module: one-way mirror of the whole vault (minus .git,
# .obsidian, .trash and `4. Archive/`) to the Google Drive folder
# "readpeakVault", so cloud scheduled tasks (Claude Cowork, Drive connector)
# can read it without the git-crypt key. Drive is a disposable mirror; git
# stays the source of truth. The export refuses to upload while that folder
# or anything in it is shared with anyone but the owner.
#
# One-time setup (interactive OAuth, token stays out of the repo):
#   rclone config create gdrive drive scope=drive.file
# drive.file limits rclone to files it created itself.
let
  cfg = config.kirocrew;
  enabled = cfg.enable && cfg.role == "workstation" && config.readpeak.enable;

  vault = "${config.home.homeDirectory}/Obsidian/Readpeak";

  exportScript = import ./vault-drive-export-script.nix {
    inherit pkgs lib vault;
  };
in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.rclone ];

    systemd.user.services.vault-drive-export = {
      Unit = {
        Description = "Mirror the vault to the readpeakVault Drive folder";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${exportScript}/bin/vault-drive-export";
        # A failed run (offline, Drive error) retries instead of waiting an hour.
        Restart = "on-failure";
        RestartSec = "5min";
      };
    };

    systemd.user.timers.vault-drive-export = {
      Unit.Description = "Hourly vault export to Google Drive";
      Timer = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
