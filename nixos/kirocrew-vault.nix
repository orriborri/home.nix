{ pkgs, ... }:

# NixOS module: direct read-only S3 mount for the headless KiroCrew host.
# The workstation remains the vault writer and synchronizes its local Obsidian
# vault to S3 with rclone (see ../vault-sync.nix).
let
  vaultDir = "/var/lib/vault";
  displacedLocalDir = "/var/lib/vault-before-s3-mount";
  prepareMount = pkgs.writeShellScript "prepare-kirocrew-vault-mount" ''
    set -euo pipefail
    if ${pkgs.util-linux}/bin/mountpoint -q ${vaultDir}; then
      exit 0
    fi

    shopt -s dotglob nullglob
    entries=(${vaultDir}/*)
    if (( ''${#entries[@]} > 0 )); then
      backup_entries=(${displacedLocalDir}/*)
      if (( ''${#backup_entries[@]} > 0 )); then
        echo "Both ${vaultDir} and ${displacedLocalDir} contain files; refusing to overwrite the preserved local vault." >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/mv -- "''${entries[@]}" ${displacedLocalDir}/
      echo "Preserved pre-mount local vault content in ${displacedLocalDir}."
    fi
  '';
in
{
  environment.systemPackages = with pkgs; [
    fuse3
    mountpoint-s3
  ];

  programs.fuse = {
    enable = true;
    userAllowOther = true;
  };

  systemd.tmpfiles.rules = [
    "d ${vaultDir} 0755 root root -"
    "d ${displacedLocalDir} 0700 root root -"
  ];

  systemd.services.readpeak-vault-s3-mount = {
    description = "Read-only ReadPeak Obsidian vault mounted directly from S3";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [
      "kirocrew-gateway.service"
      "pasta-daemon.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = prepareMount;
      ExecStart = pkgs.writeShellScript "mount-readpeak-vault-s3" ''
        set -euo pipefail
        if ${pkgs.util-linux}/bin/mountpoint -q ${vaultDir}; then
          exit 0
        fi
        ${pkgs.mountpoint-s3}/bin/mount-s3 \
          readpeak-vault-sync \
          ${vaultDir} \
          --read-only \
          --allow-other \
          --region eu-central-1
      '';
      ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u ${vaultDir}";
    };
  };
}
