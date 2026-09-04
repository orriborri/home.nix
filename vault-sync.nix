{
  pkgs,
  lib,
  config,
  ...
}:

# Home Manager module: conflict-preserving bidirectional synchronization of the
# local Obsidian vault and S3. Headless KiroCrew hosts mount the S3 bucket
# directly and do not run rclone bisync.
let
  isHeadless = (config.kirocrew or { }).role or "workstation" == "headless";
  vaultDir = "${config.home.homeDirectory}/Obsidian/Readpeak";
  stateDir = "${config.home.homeDirectory}/.local/state/vault-sync";

  syncScript = import ./vault-bisync-script.nix {
    inherit
      pkgs
      lib
      vaultDir
      stateDir
      ;
    name = "vault-sync";
    peerName = "workstation";
    initialMode = "path1";
    awsProfile = "Sandbox";
  };
in
{
  systemd.user.services.vault-sync = lib.mkIf (!isHeadless) {
    Unit = {
      Description = "Conflict-preserving Obsidian vault sync with S3";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/vault-sync";
      UMask = "0027";
    };
  };

  # Workstation and KiroCrew timers are deliberately staggered to reduce the
  # chance of two independent bisync runs updating S3 simultaneously.
  systemd.user.timers.vault-sync = lib.mkIf (!isHeadless) {
    Unit.Description = "Sync the Obsidian vault with S3 every 10 minutes";
    Timer = {
      OnCalendar = "*:0/10";
      Persistent = true;
      Unit = "vault-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
