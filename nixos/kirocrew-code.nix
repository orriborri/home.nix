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
  # Pinned CRG version, installed as a uv tool under the kirocrew user by
  # code-review-graph-install.service.
  crgVersion = "2.3.8";
  crgBin = "/var/lib/kirocrew/.local/bin/code-review-graph";
  manifest = builtins.fromTOML (builtins.readFile ../config/repos.toml);
  headlessRepos = builtins.filter (
    repo:
    builtins.elem "headless" (
      repo.targets or [
        "workstation"
        "headless"
      ]
    )
  ) manifest.repos;
  destinationFor = repo: "${codeDir}/${lib.removePrefix "code/" repo.path}";
  worktreeFor = repo: "${codeDir}/wt/${lib.removePrefix "code/" repo.path}";
  # Repos the Code Review Graph should index. Opt out per-repo with
  # `graph = false` in repos.toml (e.g. skill/doc repos that aren't code).
  graphedRepos = builtins.filter (repo: (repo.graph or true) != false) headlessRepos;
  # All intermediate parent directories of the per-repo worktree dirs
  # (e.g. "readpeak" for "readpeak/cloudformation"). Declared as group-owned
  # tmpfiles dirs so systemd-tmpfiles doesn't leave them root:root 0755 when
  # auto-creating the leaf. Deduplicated; derived from the manifest so it stays
  # correct if repo paths change.
  worktreeParentDirs =
    let
      relPaths = map (repo: lib.removePrefix "code/" repo.path) headlessRepos;
      # For "a/b/c" produce [ "a" "a/b" ]; for a top-level "a" produce [ ].
      parentsOf =
        rel:
        let
          parts = lib.splitString "/" rel;
          dirParts = lib.init parts; # drop the final path component
        in
        lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) dirParts)) (lib.length dirParts);
    in
    lib.unique (lib.concatMap parentsOf relPaths);
  mirrorFor =
    repo: "${mirrorDir}/${builtins.substring 0 16 (builtins.hashString "sha256" repo.remote)}.git";
  safeGitConfig = pkgs.writeText "kirocrew-code-review-graph-gitconfig" (
    "[safe]\n" + lib.concatMapStrings (repo: "\tdirectory = ${destinationFor repo}\n") graphedRepos
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
  '') graphedRepos;

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

      # Make the repo's .git group-writable so members of code-writers (the
      # operator and the gateway/agent) can create refs and worktree admin
      # data. core.sharedRepository=group only affects newly created files, so
      # checkouts cloned before that setting — or the top-level .git dir and
      # any 0755 subdirs — stay read-only to the group without this. Setgid on
      # directories keeps new subdirs in the code-writers group. Idempotent.
      enforce_git_perms() {
        local destination="$1"
        local gitdir="$destination/.git"
        [[ -d "$gitdir" ]] || return 0
        chgrp -R code-writers "$gitdir" 2>/dev/null || true
        chmod -R g+rwX "$gitdir" 2>/dev/null || true
        find "$gitdir" -type d -exec chmod g+s {} + 2>/dev/null || true
      }

      # Drop administrative entries for worktrees whose directory has been
      # removed (e.g. under ${codeDir}/wt). Without this, deleted worktrees
      # leave dangling records in .git/worktrees/ that block re-creating a
      # worktree at the same path. Best-effort; never fails the sync.
      prune_worktrees() {
        local destination="$1"
        [[ -d "$destination/.git" ]] || return 0
        git -C "$destination" worktree prune 2>/dev/null || true
      }

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
          enforce_git_perms "$destination"
          echo "Ready: $name"
          return
        fi

        git -C "$destination" remote set-url origin "$mirror"
        git -C "$destination" config core.sharedRepository group
        if [[ -n "$(git -C "$destination" status --porcelain)" ]]; then
          enforce_git_perms "$destination"
          prune_worktrees "$destination"
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
        enforce_git_perms "$destination"
        prune_worktrees "$destination"
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

      crg=${lib.escapeShellArg crgBin}
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

  # Installs code-review-graph as a uv tool under the kirocrew user, at
  # ${crgBin}. Runs before the sync/daemon units so the binary always exists by
  # the time they start — this is what makes switch-to-configuration succeed on
  # a fresh box (the old launcher-side install ran too late, after activation).
  crgInstall = pkgs.writeShellApplication {
    name = "kirocrew-code-review-graph-install";
    runtimeInputs = with pkgs; [
      coreutils
      uv
      python313
      git
    ];
    text = ''
      set -euo pipefail
      export HOME=/var/lib/kirocrew
      export PATH="/var/lib/kirocrew/.local/bin:$PATH"

      installed=""
      if [[ -x ${lib.escapeShellArg crgBin} ]]; then
        installed="$(${lib.escapeShellArg crgBin} --version 2>/dev/null | tr -dc '0-9.' || true)"
      fi

      if [[ "$installed" != ${lib.escapeShellArg crgVersion} ]]; then
        echo "Installing code-review-graph==${crgVersion} (was: ''${installed:-none})"
        uv tool install --force "code-review-graph==${crgVersion}"
      else
        echo "code-review-graph==${crgVersion} already installed"
      fi

      # Verify the module actually imports — catches a corrupt env early.
      ${lib.escapeShellArg crgBin} --version
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${codeDir} 2775 kirocrew code-writers -"
    # Shared worktree root plus a per-repo subdirectory mirroring the checkout
    # layout (wt/<repo-relpath>). Worktrees created off the managed checkouts
    # live here — outside the checkouts themselves — so repo-sync's
    # fast-forward does not disturb them. setgid + group-writable so both the
    # operator and the gateway/agent (both in code-writers) can create and
    # edit worktrees.
    "d ${codeDir}/wt 2775 kirocrew code-writers -"
    "d ${mirrorDir} 0750 orre code-writers -"
    "d ${graphStateDir} 0750 kirocrew code-writers -"
    # CRG per-user state dir; must exist so ProtectSystem=strict can bind it
    # read-write for the sync/daemon units (the '-' optional-path form left it
    # read-only when absent, so CRG's mkdir hit a read-only FS).
    "d /var/lib/kirocrew/.code-review-graph 0750 kirocrew kirocrew -"
  ]
  # Intermediate parent dirs (e.g. wt/readpeak) as group-owned, so tmpfiles
  # doesn't leave auto-created parents root:root 0755.
  ++ map (dir: "d ${codeDir}/wt/${dir} 2775 kirocrew code-writers -") worktreeParentDirs
  ++ map (repo: "d ${worktreeFor repo} 2775 kirocrew code-writers -") headlessRepos;

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
    onSuccess = [
      "code-review-graph-sync.service"
      "kirocrew-skill-sync.service"
    ];
    onFailure = [
      "code-review-graph-sync.service"
      "kirocrew-skill-sync.service"
    ];
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

  systemd.services.code-review-graph-install = {
    description = "Install code-review-graph (uv tool) for the kirocrew user";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [
      "code-review-graph-sync.service"
      "code-review-graph-daemon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "kirocrew";
      Group = "kirocrew";
      UMask = "0022";
      ExecStart = "${crgInstall}/bin/kirocrew-code-review-graph-install";
      TimeoutStartSec = "10min";
      ReadWritePaths = [ "/var/lib/kirocrew" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  systemd.services.code-review-graph-sync = {
    description = "Build and register KiroCrew Code Review Graph indexes";
    after = [
      "repo-sync.service"
      "code-review-graph-install.service"
    ];
    requires = [ "code-review-graph-install.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "code-writers";
      UMask = "0002";
      ExecStart = "${graphSync}/bin/kirocrew-code-review-graph-sync";
      Environment = "GIT_CONFIG_GLOBAL=${safeGitConfig}";
      ReadWritePaths = [
        codeDir
        graphStateDir
        "/var/lib/kirocrew/.code-review-graph"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  systemd.services.code-review-graph-daemon = {
    description = "Code Review Graph repository watcher";
    wants = [ "code-review-graph-sync.service" ];
    after = [
      "code-review-graph-sync.service"
      "code-review-graph-install.service"
    ];
    requires = [ "code-review-graph-install.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "kirocrew";
      Group = "code-writers";
      UMask = "0002";
      ExecStartPre = "-${crgBin} daemon stop";
      ExecStart = "${crgBin} daemon start --foreground";
      Environment = "GIT_CONFIG_GLOBAL=${safeGitConfig}";
      Restart = "on-failure";
      RestartSec = 5;
      ReadWritePaths = [
        codeDir
        graphStateDir
        "/var/lib/kirocrew/.code-review-graph"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  # ── Skill sync: copy agentskills.io SKILL.md files into the gateway ────────
  # After repo-sync refreshes the mattpocock-skills checkout, this oneshot
  # copies every SKILL.md into the KiroCrew skills directory where the gateway
  # picks them up automatically (no restart needed). Each skill is named by its
  # directory path (e.g. "tdd.md", "grill-with-docs.md") so it's identifiable
  # in the dashboard and via Slack slash-commands.
  systemd.services.kirocrew-skill-sync = {
    description = "Sync agent skills from managed checkouts into KiroCrew";
    after = [ "repo-sync.service" ];
    wantedBy = [ ]; # not standalone; triggered by repo-sync success
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "kirocrew";
      UMask = "0022";
      ExecStart = pkgs.writeShellScript "kirocrew-skill-sync" ''
        set -euo pipefail
        skills_dir="/var/lib/kirocrew/.kiro/crew/skills"
        source_dir="${codeDir}/mattpocock-skills/skills"
        mkdir -p "$skills_dir"

        if [[ ! -d "$source_dir" ]]; then
          echo "Skills source not yet checked out at $source_dir; skipping."
          exit 0
        fi

        synced=0
        # Walk every SKILL.md in the repo and copy it into the gateway skills
        # dir, named by its parent directory (the skill's slug).
        while IFS= read -r -d "" skill_file; do
          skill_dir="$(dirname "$skill_file")"
          skill_name="$(basename "$skill_dir")"
          dest="$skills_dir/$skill_name.md"

          # Only copy if the source is newer or the destination is missing.
          if [[ ! -e "$dest" ]] || [[ "$skill_file" -nt "$dest" ]]; then
            cp "$skill_file" "$dest"
            synced=$((synced + 1))
          fi
        done < <(find "$source_dir" -name 'SKILL.md' -print0)

        echo "Skill sync complete: $synced file(s) updated."
      '';
      ReadOnlyPaths = [ codeDir ];
      ReadWritePaths = [ "/var/lib/kirocrew" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}
