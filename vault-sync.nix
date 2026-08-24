{
  pkgs,
  lib,
  config,
  ...
}:

# Home Manager module: bidirectional sync of the Obsidian vault to/from S3.
# Runs every 5 minutes. Pushes local changes first, then pulls remote changes.
# Only active on the local workstation — EC2 uses mount-s3 directly.
# Disabled when the vault path is an S3 mount (avoids syncing to itself).
let
  isEC2 = builtins.pathExists /etc/NIXOS && builtins.pathExists /etc/ec2-metadata;
  bucket = "readpeak-vault-sync";
  vaultDir = "${config.home.homeDirectory}/Obsidian/Readpeak";
  awsProfile = "Sandbox";
  region = "eu-central-1";
  excludes = builtins.concatStringsSep " " [
    "--exclude '.lancedb/*'"
    "--exclude 'attachments/*'"
    "--exclude '.obsidian/*'"
    "--exclude '.semantic_search/*'"
    "--exclude 'kiro-monitor/*'"
    "--exclude '.git/*'"
  ];

  syncScript = pkgs.writeShellScript "vault-sync" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.awscli2 pkgs.coreutils ]}:$PATH"

    VAULT="${vaultDir}"
    BUCKET="s3://${bucket}"
    PROFILE="${awsProfile}"
    REGION="${region}"

    # Bail if vault directory doesn't exist
    if [ ! -d "$VAULT" ]; then
      echo "Vault dir $VAULT does not exist, skipping"
      exit 0
    fi

    # Bail if AWS creds aren't valid (e.g. SSO expired)
    if ! aws --profile "$PROFILE" --region "$REGION" sts get-caller-identity >/dev/null 2>&1; then
      echo "AWS credentials not valid for profile $PROFILE, skipping"
      exit 0
    fi

    echo "$(date -Iseconds) Syncing vault ↔ S3..."

    # Push local → S3 (local wins on conflicts since we write here)
    aws --profile "$PROFILE" --region "$REGION" s3 sync \
      "$VAULT/" "$BUCKET/" \
      ${excludes} \
      --size-only --delete

    # Pull S3 → local (picks up changes made by EC2/kirocrew)
    aws --profile "$PROFILE" --region "$REGION" s3 sync \
      "$BUCKET/" "$VAULT/" \
      ${excludes} \
      --size-only

    echo "$(date -Iseconds) Sync complete"
  '';
in
{
  systemd.user.services.vault-sync = lib.mkIf (!isEC2) {
    Unit = {
      Description = "Bidirectional Obsidian vault sync to S3";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${syncScript}";
      # Don't fail the timer if AWS creds expire
      SuccessExitStatus = "0 1";
    };
  };

  systemd.user.timers.vault-sync = lib.mkIf (!isEC2) {
    Unit = {
      Description = "Sync Obsidian vault to S3 every 5 minutes";
    };
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
