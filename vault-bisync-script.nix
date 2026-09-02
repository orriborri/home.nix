{
  pkgs,
  lib,
  name,
  vaultDir,
  stateDir,
  peerName,
  initialMode,
  bucket ? "readpeak-vault-sync",
  region ? "eu-central-1",
  awsProfile ? null,
}:

let
  rcloneConfig = pkgs.writeText "${name}-rclone.conf" ''
    [vault-s3]
    type = s3
    provider = AWS
    env_auth = true
    region = ${region}
    ${lib.optionalString (awsProfile != null) "profile = ${awsProfile}"}
  '';

  filters = pkgs.writeText "${name}-filters" ''
    - /.lancedb/**
    - /attachments/**
    - /.obsidian/**
    - /.semantic_search/**
    - /kiro-monitor/**
    - /.git/**
    - /.sync-backups/**
  '';
in
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gnugrep
    rclone
  ];
  text = ''
    set -euo pipefail

    VAULT=${lib.escapeShellArg vaultDir}
    STATE=${lib.escapeShellArg stateDir}
    REMOTE=${lib.escapeShellArg "vault-s3:${bucket}"}
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    LOG="$STATE/run-$RUN_ID.log"
    LOCAL_BACKUP="$STATE/backups/$RUN_ID"
    REMOTE_BACKUP=${lib.escapeShellArg "vault-s3:${bucket}/.sync-backups/${peerName}"}/$RUN_ID

    mkdir -p "$VAULT" "$STATE/bisync" "$STATE/backups" "$STATE/conflicts" "$STATE/failures"

    args=(
      bisync "$VAULT/" "$REMOTE/"
      --config ${rcloneConfig}
      --workdir "$STATE/bisync"
      --filters-file ${filters}
      --compare "size,checksum"
      --resilient
      --recover
      --max-lock "15m"
      --max-delete 25
      --check-sync "true"
      --conflict-resolve "none"
      --conflict-loser "num"
      --conflict-suffix "conflict"
      --backup-dir1 "$LOCAL_BACKUP"
      --backup-dir2 "$REMOTE_BACKUP"
      --log-level INFO
    )

    if [[ ! -e "$STATE/initialized" ]]; then
      echo "Initializing vault bisync; preserving replaced files in local and S3 backup paths."
      args+=(--resync-mode ${lib.escapeShellArg initialMode})
    fi

    set +e
    rclone "''${args[@]}" 2>&1 | tee "$LOG"
    status="''${PIPESTATUS[0]}"
    set -e

    if [[ "$status" -ne 0 ]]; then
      mv "$LOG" "$STATE/failures/$RUN_ID.log"
      echo "Vault bisync failed; log retained at $STATE/failures/$RUN_ID.log" >&2
      exit "$status"
    fi

    touch "$STATE/initialized"

    conflict_list="$STATE/conflicts/$RUN_ID.files"
    find "$VAULT" -type f -name '*.conflict[0-9]*' -print | sort > "$conflict_list"
    if [[ -s "$conflict_list" ]]; then
      {
        echo "Unresolved vault conflicts detected at $(date -Iseconds):"
        cat "$conflict_list"
      } > "$STATE/CONFLICTS"
      mv "$LOG" "$STATE/conflicts/$RUN_ID.log"
      echo "Vault sync preserved conflicting versions. Resolve files listed in $STATE/CONFLICTS." >&2
      exit 2
    fi

    rm -f "$STATE/CONFLICTS" "$conflict_list" "$LOG"
    echo "Vault bisync complete."
  '';
}
