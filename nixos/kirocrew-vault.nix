{
  config,
  lib,
  pkgs,
  ...
}:

# NixOS module: Git-backed constrained vault workflow.
#
# The canonical vault remains at the operator's local workstation
# (/home/orre/Obsidian/Readpeak). This module sets up a private Git
# checkout on the cloud workspace that agents can read and write to
# under strict path constraints.
#
# Design:
#   - A bare vault Git repository is the synchronization layer.
#   - The cloud workspace has a checkout at /var/lib/vault.
#   - Agents (kirocrew user) write only to approved PARA paths via a
#     helper script that validates paths before staging.
#   - Commits go to agent branches; protected branches require review.
#   - The local vault pulls and merges reviewed changes.
#   - Deletions go through Git (recoverable via history), not rm.
let
  vaultCheckout = "/var/lib/vault";

  # Approved PARA paths that agents may write to.
  # Paths outside this list are rejected by the commit helper.
  allowedPaths = [
    "1. Projects/"
    "2. Areas/"
    "3. Resources/"
    "4. Archive/"
    "People/"
    "Meetings/"
    "Tasks/"
    "Roadmap/"
  ];

  allowedPathsStr = lib.concatMapStringsSep "\n" (p: "  '${p}'") allowedPaths;

  # Helper script: validates changed files against allowed paths, then commits.
  # Runs as kirocrew but the vault checkout is group-writable for vault-readers
  # only through this controlled interface.
  vaultCommitHelper = pkgs.writeShellApplication {
    name = "vault-commit";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
    ];
    text = ''
      set -euo pipefail

      VAULT_DIR="${vaultCheckout}"
      BRANCH_PREFIX="agent/"

      usage() {
        echo "Usage: vault-commit [-m message] [file ...]"
        echo ""
        echo "Stage and commit vault changes on an agent branch."
        echo "Only files under approved PARA paths are accepted."
        echo "If no files are specified, all modified tracked files are staged."
        exit 1
      }

      message=""
      files=()

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -m) message="$2"; shift 2 ;;
          -h|--help) usage ;;
          *) files+=("$1"); shift ;;
        esac
      done

      if [[ -z "$message" ]]; then
        echo "error: commit message required (-m)" >&2
        exit 1
      fi

      cd "$VAULT_DIR"

      # Ensure we are on an agent branch.
      current_branch="$(git rev-parse --abbrev-ref HEAD)"
      if [[ "$current_branch" != "$BRANCH_PREFIX"* ]]; then
        agent_branch="''${BRANCH_PREFIX}$(date +%Y%m%d-%H%M%S)"
        git checkout -b "$agent_branch"
        echo "Created agent branch: $agent_branch"
      fi

      # Collect files to validate.
      if [[ ''${#files[@]} -eq 0 ]]; then
        mapfile -t files < <(git diff --name-only; git diff --name-only --cached)
      fi

      if [[ ''${#files[@]} -eq 0 ]]; then
        echo "No changes to commit."
        exit 0
      fi

      # Validate each file against allowed paths.
      allowed_patterns=(
      ${allowedPathsStr}
      )

      for f in "''${files[@]}"; do
        allowed=0
        for pattern in "''${allowed_patterns[@]}"; do
          if [[ "$f" == "$pattern"* ]]; then
            allowed=1
            break
          fi
        done
        if [[ "$allowed" -eq 0 ]]; then
          echo "error: file outside approved paths: $f" >&2
          echo "Allowed path prefixes:" >&2
          for pattern in "''${allowed_patterns[@]}"; do
            echo "  $pattern" >&2
          done
          exit 1
        fi
      done

      # Stage validated files and commit.
      git add -- "''${files[@]}"
      git commit -m "$message" --author="KiroCrew Agent <kirocrew@localhost>"
      echo "Committed ''${#files[@]} file(s) on $(git rev-parse --abbrev-ref HEAD)"
    '';
  };

  # Helper script: sync vault from remote (pull latest main).
  vaultSyncHelper = pkgs.writeShellApplication {
    name = "vault-sync";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = ''
      set -euo pipefail
      cd "${vaultCheckout}"

      # Fetch all branches.
      git fetch --all --prune

      # If on main, pull fast-forward only.
      current_branch="$(git rev-parse --abbrev-ref HEAD)"
      if [[ "$current_branch" == "main" ]]; then
        git pull --ff-only origin main
      else
        echo "On branch $current_branch; run 'git checkout main && vault-sync' to update."
      fi
    '';
  };
in
{
  # Install the vault helper scripts system-wide.
  environment.systemPackages = [
    vaultCommitHelper
    vaultSyncHelper
  ];

  # ── Git configuration for the vault checkout ───────────────────────────────
  # The vault checkout is initialized manually or by a bootstrap script.
  # This activation script ensures the directory and basic Git config exist.
  system.activationScripts.vault-git-config = lib.stringAfter [ "users" ] ''
    if [ -d "${vaultCheckout}/.git" ]; then
      # Ensure the checkout is safe for all vault-readers members.
      ${pkgs.git}/bin/git -C "${vaultCheckout}" config --local safe.directory "${vaultCheckout}"

      # Prevent direct pushes to protected branches.
      ${pkgs.git}/bin/git -C "${vaultCheckout}" config --local branch.main.pushRemote no-push
    fi
  '';

  # ── Periodic vault sync (pull from remote) ─────────────────────────────────
  # Runs every 15 minutes to keep the cloud checkout current with the
  # authoritative vault. Runs as root because the checkout is root:vault-readers.
  systemd.services.vault-sync = {
    description = "Sync vault checkout from remote";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${vaultSyncHelper}/bin/vault-sync";
      WorkingDirectory = vaultCheckout;
    };
  };

  systemd.timers.vault-sync = {
    description = "Periodic vault sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
      RandomizedDelaySec = "2min";
    };
  };
}
