{
  lib,
  pkgs,
  ...
}:

# NixOS module: local writable Obsidian vault synchronized bidirectionally with
# S3. The local filesystem remains the agent write path; Mountpoint is exposed
# separately as a read-only inspection/recovery view by kirocrew-ec2.nix.
let
  vaultDir = "/var/lib/vault";
  stateDir = "/var/lib/vault-sync";

  syncScript = import ../vault-bisync-script.nix {
    inherit
      pkgs
      lib
      vaultDir
      stateDir
      ;
    name = "kirocrew-vault-sync";
    peerName = "kirocrew";
    initialMode = "path2";
  };
in
{
  environment.systemPackages = [ syncScript ];

  # KiroCrew owns the writable local copy. Pasta receives read access through
  # vault-readers; the sync state remains private to KiroCrew.
  systemd.tmpfiles.rules = [
    "d ${vaultDir} 2750 kirocrew vault-readers -"
    "d ${stateDir} 0700 kirocrew kirocrew -"
  ];

  systemd.services.vault-sync = {
    description = "Conflict-preserving KiroCrew vault sync with S3";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "kirocrew";
      UMask = "0027";
      ExecStart = "${syncScript}/bin/kirocrew-vault-sync";
      WorkingDirectory = vaultDir;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadWritePaths = [
        vaultDir
        stateDir
      ];
    };
  };

  # Staggered five minutes after the workstation's ten-minute cadence.
  systemd.timers.vault-sync = {
    description = "Sync the KiroCrew vault with S3 every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:5/10";
      Persistent = true;
      Unit = "vault-sync.service";
    };
  };
}
