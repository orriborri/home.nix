{
  lib,
  pkgs,
  ...
}:

# NixOS module: KiroCrew owns the Obsidian vault as a git-crypt-encrypted git
# repository (Model 2). This replaces the read-only S3 mount at /var/lib/vault.
#
# The gateway (kirocrew) reads and writes the vault working tree directly. A
# clone/unlock service establishes the checkout; a push service commits and
# pushes the agent's changes.
#
# Auth: HTTPS with a GitLab deploy token. The token username and value are
# provisioned to the kirocrew user as sops secrets (kirocrew-sops.nix). The
# token is fed to git via GIT_ASKPASS at runtime so it never lands in
# .git/config on disk. The git-crypt key (also a sops secret) unlocks content.
let
  vaultDir = "/var/lib/vault";
  keyDir = "/var/lib/kirocrew/secrets";
  tokenFile = "${keyDir}/vault-git-token";
  tokenUserFile = "${keyDir}/vault-git-token-user";
  cryptKey = "${keyDir}/vault-git-crypt-key";
  repoHost = "gitlab.com";
  repoPath = "orriborri/Vault.git";
  repoBranch = "main";

  # One advisory lock guards both clone and sync so overlapping timer runs and
  # a late-starting clone cannot race each other. The sync script takes this
  # same path via fcntl; the clone service takes it via flock(1) (util-linux).
  lockFile = "${vaultDir}/.git/kirocrew-sync.lock";

  # GIT_ASKPASS helper: git calls it for "Username" and "Password" prompts.
  # We answer from the sops-provisioned secret files, so the token is never
  # written into the repo's remote URL or config.
  askpass = pkgs.writeShellScript "kirocrew-vault-askpass" ''
    case "$1" in
      *Username*) cat ${lib.escapeShellArg tokenUserFile} ;;
      *Password*) cat ${lib.escapeShellArg tokenFile} ;;
      *) exit 1 ;;
    esac
  '';

  # Common git environment: non-interactive, token via askpass, stable author.
  gitEnv = ''
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS=${askpass}
    export GIT_AUTHOR_NAME="KiroCrew"
    export GIT_AUTHOR_EMAIL="kirocrew@readpeak"
    export GIT_COMMITTER_NAME="KiroCrew"
    export GIT_COMMITTER_EMAIL="kirocrew@readpeak"
    # Plain https URL — no credentials embedded; askpass supplies them.
    REMOTE_URL="https://${repoHost}/${repoPath}"
  '';

  vaultClone = pkgs.writeShellApplication {
    name = "kirocrew-vault-clone";
    runtimeInputs = with pkgs; [
      coreutils
      git
      git-crypt
      util-linux
    ];
    text = ''
      set -euo pipefail
      umask 0007
      ${gitEnv}

      # Wait for the sops-provisioned secrets to appear (whichever unit writes
      # them). Avoids a hard dependency on a specific sops unit name.
      for _ in $(seq 1 30); do
        if [[ -r "${tokenFile}" && -r "${tokenUserFile}" && -r "${cryptKey}" ]]; then
          break
        fi
        sleep 2
      done
      for f in ${tokenFile} ${tokenUserFile} ${cryptKey}; do
        if [[ ! -r "$f" ]]; then
          echo "Required secret not provisioned: $f" >&2
          exit 1
        fi
      done

      if [[ -d "${vaultDir}/.git" ]]; then
        echo "Vault repo already present; fetching."
        git -C "${vaultDir}" remote set-url origin "$REMOTE_URL"
        git -C "${vaultDir}" fetch --prune origin
      else
        # Fresh clone. The vault dir already exists (tmpfiles) and may be
        # empty; git clone refuses a non-empty target, so clone into a temp
        # dir and move everything (including .git) in one glob.
        tmp="$(mktemp -d)"
        git clone --branch ${repoBranch} "$REMOTE_URL" "$tmp/repo"
        shopt -s dotglob
        mv "$tmp/repo"/* "${vaultDir}/"
        rm -rf "$tmp"
      fi

      # Ensure the branch tracks its upstream so the sync script can validate a
      # push destination instead of guessing. Reconciling incoming/divergent
      # history is the sync script's job (under the shared lock); clone only
      # establishes and unlocks the checkout.
      git -C "${vaultDir}" branch --set-upstream-to=origin/${repoBranch} ${repoBranch} \
        2>/dev/null || true

      # Unlock git-crypt content. The sops secret holds base64 of the raw key.
      raw="$(mktemp)"
      if base64 -d "${cryptKey}" > "$raw" 2>/dev/null && [[ -s "$raw" ]]; then
        :
      else
        cp "${cryptKey}" "$raw"
      fi
      ( cd "${vaultDir}" && git-crypt unlock "$raw" )
      rm -f "$raw"
      echo "Vault checked out and unlocked at ${vaultDir}."
    '';
  };

  # Retryable commit + reconcile + push. The heavy logic lives in a tested
  # Python script (scripts/kirocrew_vault_sync.py, tests/test_vault_sync.py);
  # this wrapper only supplies the git environment and PATH. The script takes
  # the shared lock (${lockFile}) via fcntl, commits only when the tree is
  # dirty, always fetches, fast-forwards or rebases conservatively, and pushes
  # any outgoing commits — so a previously failed push retries on a clean tree.
  vaultSync = pkgs.writeShellApplication {
    name = "kirocrew-vault-sync";
    runtimeInputs = with pkgs; [
      coreutils
      git
      git-crypt
    ];
    text = ''
      set -euo pipefail
      umask 0007
      ${gitEnv}
      git -C "${vaultDir}" remote set-url origin "$REMOTE_URL" 2>/dev/null || true
      exec ${pkgs.python3}/bin/python3 ${./scripts/kirocrew_vault_sync.py} \
        --vault-dir "${vaultDir}" \
        --lock-file "${lockFile}" \
        --message "KiroCrew vault update $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    git
    git-crypt
  ];

  # Vault is a git working tree owned by the gateway; readable by pasta via
  # vault-readers. Not world-readable.
  systemd.tmpfiles.rules = [
    "d ${vaultDir} 2750 kirocrew vault-readers -"
  ];

  systemd.services.kirocrew-vault-clone = {
    description = "Clone and unlock the KiroCrew git vault";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "kirocrew-gateway.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "kirocrew";
      Group = "kirocrew";
      UMask = "0007";
      ExecStart = "${vaultClone}/bin/kirocrew-vault-clone";
      ReadWritePaths = [
        vaultDir
        "/var/lib/kirocrew"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.services.kirocrew-vault-sync = {
    description = "Commit, reconcile, and push KiroCrew vault changes (retryable)";
    after = [ "kirocrew-vault-clone.service" ];
    requires = [ "kirocrew-vault-clone.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "kirocrew";
      UMask = "0007";
      ExecStart = "${vaultSync}/bin/kirocrew-vault-sync";
      ReadWritePaths = [
        vaultDir
        "/var/lib/kirocrew"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  # Periodically persist and push agent edits. A run that fails (e.g. push
  # rejected, remote briefly unreachable) leaves local commits intact; the next
  # timed run fetches, reconciles, and retries the push even on a clean tree.
  systemd.timers.kirocrew-vault-sync = {
    description = "Sync KiroCrew vault every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "10m";
      Persistent = true;
      RandomizedDelaySec = "30s";
      Unit = "kirocrew-vault-sync.service";
    };
  };
}
