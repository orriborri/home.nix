{
  lib,
  pkgs,
  ...
}:

# NixOS module: protected repository mirrors, agent-owned working trees, and
# automatic Code Review Graph maintenance.
let
  codeDir = "/var/lib/code";
  mirrorDir = "/var/lib/kirocrew-repo-mirrors";
  graphStateDir = "/var/lib/code-review-graph";
  manifest = builtins.fromTOML (builtins.readFile ../config/repos.toml);
  headlessRepos = builtins.filter (
    repo: builtins.elem "headless" (repo.targets or [
      "workstation"
      "headless"
    ])
  ) manifest.repos;
  destinationFor = repo: "${codeDir}/${lib.removePrefix "code/" repo.path}";
  mirrorFor = repo: "${mirrorDir}/${builtins.substring 0 16 (builtins.hashString "sha256" repo.remote)}.git";
  safeGitConfig = pkgs.writeText "kirocrew-code-review-graph-gitconfig" (
    "[safe]\n"
    + lib.concatMapStrings (repo: "\tdirectory = ${destinationFor repo}\n") headlessRepos
  );

  fetchCommands = lib.concatMapStringsSep "\n" (repo: ''
    fetch_mirror \
      ${lib.escapeShellArg repo.remote} \
      ${lib.escapeShellArg (mirrorFor repo)} \
      ${if (repo.shallow or true) then "1" else "0"}
  '') headlessRepos;

  checkoutCommands = lib.concatMapStringsSep "\n" (repo: ''
    update_checkout \
      ${lib.escapeShellArg (mirrorFor repo)} \
      ${lib.escapeShellArg (destinationFor repo)}
  '') headlessRepos;

  graphCommands = lib.concatMapStringsSep "\n" (repo: ''
    sync_graph \
      ${lib.escapeShellArg (destinationFor repo)} \
      ${lib.escapeShellArg (builtins.baseNameOf repo.path)}
  '') headlessRepos;

  repoFetch = pkgs.writeShellApplication {
    name = "kirocrew-repo-fetch";
    runtimeInputs = with pkgs; [
      coreutils
      git
      openssh
    ];
    text = ''
      set -uo pipefail
      umask 0027

      runtime_dir="/run/user/$(id -u)"
      git_key="$runtime_dir/secrets/git-ssh-key"
      known_hosts="/home/orre/.ssh/known_hosts_kirocrew"
      failures=0

      if [[ ! -r "$git_key" ]]; then
        echo "Git SSH key is unavailable at $git_key" >&2
        exit 1
      fi
      if [[ ! -r "$known_hosts" ]]; then
        echo "Declarative Git known_hosts is unavailable at $known_hosts" >&2
        exit 1
      fi

      export GIT_SSH_COMMAND="ssh -i $git_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=15"

      fetch_mirror() {
        local remote="$1"
        local mirror="$2"
        local shallow="$3"
        local clone_args=(--mirror)

        if [[ "$shallow" == "1" ]]; then
          clone_args+=(--depth=1)
        fi
        if [[ -e "$mirror" && ! -d "$mirror/objects" ]]; then
          echo "Mirror destination is not a bare Git repository: $mirror" >&2
          failures=$((failures + 1))
          return
        fi
        if [[ ! -d "$mirror/objects" ]]; then
          echo "Creating protected mirror for $remote..."
          if ! git clone "''${clone_args[@]}" "$remote" "$mirror"; then
            echo "Mirror clone failed: $remote" >&2
            failures=$((failures + 1))
            return
          fi
        else
          git -C "$mirror" remote set-url origin "$remote"
          if ! git -C "$mirror" fetch --prune origin; then
            echo "Mirror fetch failed: $remote" >&2
            failures=$((failures + 1))
            return
          fi
        fi
        chmod -R u+rwX,g+rX,go-w "$mirror"
      }

      ${fetchCommands}

      if (( failures > 0 )); then
        echo "$failures mirror fetch operation(s) need attention" >&2
        exit 1
      fi
    '';
  };

  repoCheckout = pkgs.writeShellApplication {
    name = "kirocrew-repo-checkout-sync";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
    ];
    text = ''
      set -uo pipefail
      umask 0002
      failures=0
      warnings=0

      # Mirrors are owned by orre but read by kirocrew via the code-writers
      # group. Git refuses cross-owner repositories unless declared safe.
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0=safe.directory
      export GIT_CONFIG_VALUE_0='*'

      update_checkout() {
        local mirror="$1"
        local destination="$2"
        local name
        name="$(basename "$destination")"

        if [[ ! -d "$mirror/objects" ]]; then
          echo "Skipping unavailable mirror: $name" >&2
          failures=$((failures + 1))
          return
        fi
        if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
          echo "Checkout destination is not a Git repository: $destination" >&2
          failures=$((failures + 1))
          return
        fi
        if [[ ! -d "$destination/.git" ]]; then
          mkdir -p "$(dirname "$destination")"
          if ! git clone --config core.sharedRepository=group "$mirror" "$destination"; then
            echo "Checkout clone failed: $name" >&2
            failures=$((failures + 1))
            return
          fi
          echo "Ready: $name"
          return
        fi

        git -C "$destination" remote set-url origin "$mirror"
        git -C "$destination" config core.sharedRepository group
        if [[ -n "$(git -C "$destination" status --porcelain)" ]]; then
          echo "Skipping dirty checkout (preserved, not reset): $name"
          warnings=$((warnings + 1))
          return
        fi
        if ! git -C "$destination" fetch --prune origin; then
          echo "Local fetch failed: $name" >&2
          failures=$((failures + 1))
          return
        fi
        upstream="$(git -C "$destination" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
        if [[ -z "$upstream" ]] || ! git -C "$destination" merge --ff-only "$upstream"; then
          echo "Fast-forward failed or no upstream exists: $name" >&2
          failures=$((failures + 1))
          return
        fi
        echo "Updated: $name"
      }

      ${checkoutCommands}

      if (( warnings > 0 )); then
        echo "$warnings checkout(s) preserved as dirty and left untouched"
      fi
      if (( failures > 0 )); then
        echo "$failures checkout operation(s) need attention" >&2
        exit 1
      fi
    '';
  };

  graphSync = pkgs.writeShellApplication {
    name = "kirocrew-code-review-graph-sync";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = ''
      set -uo pipefail
      umask 0002

      crg="/home/orre/.local/bin/code-review-graph"
      failures=0
      present=0
      mkdir -p ${lib.escapeShellArg graphStateDir}/revisions

      if [[ ! -x "$crg" ]]; then
        echo "code-review-graph is not installed at $crg" >&2
        exit 1
      fi

      sync_graph() {
        local repository="$1"
        local alias="$2"
        local fingerprint stamp previous=""

        if [[ ! -d "$repository/.git" ]]; then
          echo "Skipping absent repository: $repository"
          return
        fi
        present=$((present + 1))

        fingerprint="$({ git -C "$repository" rev-parse HEAD; git -C "$repository" status --porcelain=v1 -z; } | sha256sum | cut -d' ' -f1)"
        stamp="${graphStateDir}/revisions/$(printf '%s' "$repository" | sha256sum | cut -d' ' -f1)"
        if [[ -r "$stamp" ]]; then
          previous="$(<"$stamp")"
        fi

        if [[ ! -d "$repository/.code-review-graph" ]]; then
          echo "Installing graph metadata: $alias"
          if ! "$crg" install --repo "$repository" --platform kiro --no-hooks --no-instructions -y; then
            echo "Graph installation failed: $alias" >&2
            failures=$((failures + 1))
            return
          fi
        fi
        if [[ "$fingerprint" != "$previous" ]]; then
          echo "Building graph: $alias"
          if ! "$crg" build --repo "$repository"; then
            echo "Graph build failed: $alias" >&2
            failures=$((failures + 1))
            return
          fi
          printf '%s\n' "$fingerprint" > "$stamp"
        else
          echo "Graph current: $alias"
        fi
        if ! "$crg" daemon add "$repository" --alias "$alias"; then
          # An alias left over from a previous location blocks re-registration.
          # Remove it and retry so the daemon tracks the current path.
          "$crg" daemon remove "$alias" >/dev/null 2>&1 || true
          if ! "$crg" daemon add "$repository" --alias "$alias"; then
            echo "Daemon registration failed: $alias" >&2
            failures=$((failures + 1))
          fi
        fi
      }

      ${graphCommands}

      if (( present == 0 )); then
        echo "No repositories present yet; graph sync will run again after repo-sync populates /var/lib/code."
        exit 0
      fi
      if (( failures > 0 )); then
        echo "$failures graph operation(s) need attention" >&2
        exit 1
      fi
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${codeDir} 2775 kirocrew code-writers -"
    "d ${mirrorDir} 0750 orre code-writers -"
    "d ${graphStateDir} 0750 orre code-writers -"
  ];

  systemd.services.repo-fetch = {
    description = "Fetch protected KiroCrew repository mirrors";
    after = [
      "network-online.target"
      "home-manager-orre.service"
    ];
    wants = [ "network-online.target" ];
    onSuccess = [ "repo-sync.service" ];
    onFailure = [ "repo-sync.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "orre";
      Group = "code-writers";
      UMask = "0027";
      ExecStart = "${repoFetch}/bin/kirocrew-repo-fetch";
      ReadWritePaths = [ mirrorDir ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  systemd.timers.repo-fetch = {
    description = "Fetch KiroCrew repositories every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
      Persistent = true;
      RandomizedDelaySec = "30s";
      Unit = "repo-fetch.service";
    };
  };

  systemd.services.repo-sync = {
    description = "Update KiroCrew working trees from protected mirrors";
    after = [ "repo-fetch.service" ];
    onSuccess = [ "code-review-graph-sync.service" ];
    onFailure = [ "code-review-graph-sync.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "code-writers";
      UMask = "0002";
      ExecStart = "${repoCheckout}/bin/kirocrew-repo-checkout-sync";
      ReadOnlyPaths = [ mirrorDir ];
      ReadWritePaths = [ codeDir ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.services.code-review-graph-sync = {
    description = "Build and register KiroCrew Code Review Graph indexes";
    after = [ "repo-sync.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "orre";
      Group = "code-writers";
      UMask = "0002";
      ExecStart = "${graphSync}/bin/kirocrew-code-review-graph-sync";
      Environment = "GIT_CONFIG_GLOBAL=${safeGitConfig}";
      ReadWritePaths = [
        codeDir
        graphStateDir
        "-/home/orre/.code-review-graph"
      ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  systemd.services.code-review-graph-daemon = {
    description = "Code Review Graph repository watcher";
    wants = [ "code-review-graph-sync.service" ];
    after = [ "code-review-graph-sync.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "orre";
      Group = "code-writers";
      UMask = "0002";
      ExecStartPre = "-/home/orre/.local/bin/code-review-graph daemon stop";
      ExecStart = "/home/orre/.local/bin/code-review-graph daemon start --foreground";
      Environment = "GIT_CONFIG_GLOBAL=${safeGitConfig}";
      Restart = "on-failure";
      RestartSec = 5;
      ReadWritePaths = [
        codeDir
        graphStateDir
        "-/home/orre/.code-review-graph"
      ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}
