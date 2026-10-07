{ lib, pkgs, ... }:

# NixOS module: the Pasta daemon, its periodic vault indexer and external
# fetch timers, the source build they share, and the ACL grant that lets the
# pasta user rewrite the vault's .feeds/ directory. Runs under the dedicated
# `pasta` user; the kb store it writes is read by the kb-mcp server the
# KiroCrew gateway (kirocrew-services.nix) spawns. Split out of
# kirocrew-services.nix, which keeps the pasta tmpfiles rules.
#
# Replaces the Home Manager user service (pasta-service.nix) on headless/EC2
# hosts, where the workstation module is not imported.
let
  hardening = import ./kirocrew-hardening.nix;
  pastaHome = "/var/lib/pasta";

  # The kb store (LanceDB + Tantivy index). Written by the pasta indexer and
  # read by the kb-mcp server the gateway spawns. Group-readable via the
  # shared vault-readers group (see kirocrew-security.nix + the tmpfiles rules
  # in kirocrew-services.nix). Same value as in kirocrew-services.nix.
  pastaDataDir = "${pastaHome}/data";

  # Vault checkout location — kirocrew and pasta read via vault-readers group.
  vaultCheckout = "/var/lib/vault";

  pastaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];

  # ── Pasta external-source fetch helpers ─────────────────────────────────────
  # The slack and linear kb-fetchers shell out to small helper CLIs (`slack-api`,
  # `linear-api`) rather than embedding tokens. On the workstation these live in
  # the vault's .scripts/bin; here we package the exact same scripts as store
  # binaries with pinned interpreters so they run under the pasta unit's strict
  # sandbox with no PATH assumptions. Each reads its token from
  # ~/.config/<tool>-api/token.json; the fetch unit reconstructs these from
  # sops. Slack prefers SLACK_BOT_TOKEN from the unit environment.
  pastaSlackApi = pkgs.writeShellApplication {
    name = "slack-api";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./pasta-fetch-bin/slack-api} "$@"
    '';
  };
  pastaLinearApi = pkgs.writeShellApplication {
    name = "linear-api";
    runtimeInputs = [
      pkgs.bash
      pkgs.curl
      pkgs.python3
    ];
    text = ''exec ${pkgs.bash}/bin/bash ${./pasta-fetch-bin/linear-api} "$@"'';
  };
  # Directory placed on the fetch unit's PATH so pasta's binary auto-detection
  # (empty [binaries].slack_api/linear_api = "resolve from PATH") finds them.
  pastaFetchBin = pkgs.symlinkJoin {
    name = "pasta-fetch-bin";
    paths = [
      pastaSlackApi
      pastaLinearApi
    ];
  };

  # Secret-dependent setup for the external fetch, run as an ExecStartPre of the
  # pasta-fetch-external unit (so it executes as the pasta user, which owns the
  # decrypted sops secrets). It (1) reconstructs the token.json files the helper
  # CLIs read, (2) logs glab in with the token for MR fetch, and (3) clones or
  # updates the git repos over HTTPS using the same token (no SSH key needed).
  # Idempotent: safe to run on every timer firing.
  # GIT_ASKPASS helper for pasta's GitLab clones: git asks it for the username
  # and password, so the token never appears in a URL, argv or .git/config.
  pastaGitAskpass = pkgs.writeShellScript "pasta-git-askpass" ''
    case "$1" in
      *Username*) echo oauth2 ;;
      *Password*) cat ${pastaHome}/secrets/gitlab-token ;;
      *) exit 1 ;;
    esac
  '';

  pastaFetchSetup = pkgs.writeShellApplication {
    name = "pasta-fetch-setup";
    runtimeInputs = with pkgs; [
      coreutils
      git
      glab
      jq
    ];
    text = ''
      set -euo pipefail
      secrets="${pastaHome}/secrets"
      home="${pastaHome}"

      # Ignore any user/system git url-rewrites (e.g. https->ssh insteadOf) and
      # never prompt for credentials, so the token-authenticated HTTPS clones can't be
      # redirected to an SSH transport needing a key. Mirrors pastaSourceBuild.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0

      # Mark the repo tree as safe for pasta's git fetcher. The kb `git log`
      # step runs in a SEPARATE process (the unit's ExecStart) under
      # HOME=${pastaHome} WITHOUT GIT_CONFIG_GLOBAL, so it reads this persistent
      # ~/.gitconfig. Recent git refuses to operate on a repo dir unless trusted,
      # which otherwise makes the git source flaky ("detected dubious ownership").
      # This setup step keeps GIT_CONFIG_GLOBAL=/dev/null above (its own git ops
      # act on repos it owns in-process), so the url-rewrite guard still holds.
      printf '[safe]\n\tdirectory = *\n' > "${pastaHome}/.gitconfig"

      # ── Slack + Linear credentials (mode 600, pasta-owned) ──────────────
      install -d -m 700 "$home/.config/slack-api" "$home/.config/linear-api"
      slack_token="''${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN unset (pasta-fetchers.env missing?)}"
      linear_key="$(cat "$secrets/linear-api-key")"
      # Maintain the helper's token file for environments without SOPS env.
      # The helper prefers SLACK_BOT_TOKEN when the service provides it.
      jq -n --arg t "$slack_token" '{access_token:$t}' \
        > "$home/.config/slack-api/token.json"
      jq -n --arg k "$linear_key" '{api_key:$k}' \
        > "$home/.config/linear-api/token.json"
      chmod 600 "$home/.config/slack-api/token.json" "$home/.config/linear-api/token.json"

      # ── glab auth (GitLab MR fetch) ─────────────────────────────────────
      # Feed the token via stdin; never appears in argv or the store.
      GITLAB_HOST=gitlab.com
      glab auth login --hostname "$GITLAB_HOST" --stdin < "$secrets/gitlab-token" || \
        echo "warn: glab auth login failed (MR fetch may be degraded)" >&2

      # ── git repos: clone/update over HTTPS with the token ───────────────
      # The token reaches git through GIT_ASKPASS, never through the URL.
      export GIT_ASKPASS=${pastaGitAskpass}
      install -d -m 755 "$home/repos"
      clone_or_pull() {
        # $1 = local dir name, $2 = repo path on gitlab.com
        # Clone with history depth so pasta's `git log --since` fetcher sees more
        # than the latest commit (a --depth 1 clone yields only HEAD, starving
        # the git source). 500 commits covers the fetch window cheaply.
        local dir="$home/repos/$1" url="https://gitlab.com/$2.git"
        if [ -d "$dir/.git" ]; then
          git -C "$dir" remote set-url origin "$url"
          git -C "$dir" fetch --depth 500 origin HEAD && \
            git -C "$dir" reset --hard FETCH_HEAD || \
            echo "warn: update $1 failed" >&2
        else
          git clone --depth 500 "$url" "$dir" || echo "warn: clone $1 failed" >&2
        fi
      }
      clone_or_pull wiki          "readpeak.wiki"
      clone_or_pull eks-workloads "readpeak/eks-workloads"
      clone_or_pull cdk           "readpeak/cdk"
      clone_or_pull mononode      "readpeak/mononode"

      echo "pasta-fetch-setup complete"
    '';
  };

  # Source builder for the Pasta vault indexer + kb MCP server, run as an
  # ExecStartPre of the pasta-daemon system service (pasta user). Builds the
  # whole workspace so both `pasta-backend` (indexer) and `kb` (MCP stdio
  # server) are produced, and links them into ${pastaHome}/bin. Fully
  # self-contained under ${pastaHome}: clones the public repo and builds there,
  # inside the unit's single ReadWritePath. CARGO_HOME/target live under
  # ${pastaHome} so nothing is written outside the sandbox.
  #
  # Build env mirrors the repo's shell.nix (protobuf, openssl, mold) but wires
  # it explicitly rather than via nix-shell (which can't run under the strict
  # sandbox). openssl-sys needs OPENSSL_DIR/PKG_CONFIG_PATH pointing at the
  # openssl .dev output and OPENSSL_NO_VENDOR=1 to use it instead of compiling a
  # vendored copy. mold must be on PATH because the repo's .cargo/config.toml
  # sets rustflags to link with it.
  #
  # NOTE: uses the public HTTPS remote — the pasta user has no forge
  # credentials. If orriborri/pasta becomes private, switch this to a
  # deploy-token/SSH flow like kirocrew-vault-git.nix.
  # Commit of orriborri/pasta this host builds and runs under the token-holding
  # uid. Bump deliberately: git ls-remote https://github.com/orriborri/pasta.git HEAD
  pastaRev = "bcc6d5bddef1683004e717820d1e38d629abdbf9";

  pastaSourceBuild = pkgs.writeShellApplication {
    name = "pasta-source-build";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux # flock
      git
      cargo
      rustc
      gcc
      mold # repo's .cargo/config.toml links with mold
      pkg-config
      openssl
      openssl.dev
      protobuf
    ];
    text = ''
      srcRoot="${pastaHome}/src"
      binDir="${pastaHome}/bin"
      export CARGO_HOME="${pastaHome}/.cargo"
      export CARGO_TARGET_DIR="${pastaHome}/target"
      export PROTOC="${pkgs.protobuf}/bin/protoc"
      export PROTOC_INCLUDE="${pkgs.protobuf}/include"

      # openssl-sys: use the Nix system OpenSSL, do not compile a vendored copy.
      export OPENSSL_NO_VENDOR=1
      export OPENSSL_DIR="${pkgs.openssl.dev}"
      export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
      export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

      # Public, read-only checkout: ignore user Git URL rewrites so an HTTPS
      # clone can't be redirected to an SSH clone needing credentials.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0

      mkdir -p "$srcRoot" "$binDir" "$CARGO_HOME" "$CARGO_TARGET_DIR"

      # One build at a time: the daemon's pre-start, the timer units and manual
      # runs all call this, and concurrent git reset / cargo build in the same
      # checkout race. The lock lives beside src (a file inside it would break
      # the first clone) and is held until this script exits.
      exec 9>"${pastaHome}/.build.lock"
      flock 9

      # Pin the kb data dir so the indexer (this daemon, HOME=${pastaHome}) and
      # the kb-mcp server (spawned by the gateway as the kirocrew user with a
      # different HOME) resolve to the SAME store. pasta reads only
      # ${pastaHome}/.pasta/config.toml (config_path = $HOME/.pasta/config.toml);
      # there is no env override, so both users must carry this file. The
      # kirocrew copy is written by the mcp-config service below.
      mkdir -p "${pastaHome}/.pasta"
      cat > "${pastaHome}/.pasta/config.toml" <<EOF
      [general]
      vault_path = "${vaultCheckout}"
      log_level = "info"

      [kb]
      data_dir = "${pastaDataDir}"

      # External-source fetch wiring (secrets are provisioned separately by the
      # pasta-fetch-external unit; only non-secret paths/globs live here).
      [binaries]
      glab = "${pkgs.glab}/bin/glab"
      slack_api = "${pastaSlackApi}/bin/slack-api"
      linear_api = "${pastaLinearApi}/bin/linear-api"

      # Repos indexed for git history/search. Cloned over HTTPS by the fetch
      # unit's ExecStartPre using the gitlab token (no SSH key on the box).
      [[repos]]
      path = "${pastaHome}/repos/wiki"
      include = ["*.md"]

      [[repos]]
      path = "${pastaHome}/repos/eks-workloads"
      include = ["**/*.ts", "README.md"]

      [[repos]]
      path = "${pastaHome}/repos/cdk"
      include = ["**/*.ts", "README.md", "config/*.toml"]

      [[repos]]
      path = "${pastaHome}/repos/mononode"
      include = ["README.md", "docs/**", "**/*.ts"]
      EOF

      if [ ! -d "$srcRoot/.git" ]; then
        git clone --no-checkout --depth 1 https://github.com/orriborri/pasta.git "$srcRoot"
      fi
      git -C "$srcRoot" fetch --depth 1 origin ${pastaRev}
      git -C "$srcRoot" reset --hard ${pastaRev}

      cd "$srcRoot"
      # Build the whole workspace so both pasta-backend and kb are produced.
      # Rebuild when either binary is missing or sources changed.
      backend="$CARGO_TARGET_DIR/release/pasta-backend"
      kb="$CARGO_TARGET_DIR/release/kb"
      if [ ! -x "$backend" ] || [ ! -x "$kb" ] || \
         [ -n "$(find crates src -name '*.rs' -newer "$backend" 2>/dev/null | head -1)" ]; then
        echo "Building pasta workspace (release)..."
        cargo build --release
      fi

      # Link whatever got built into the bin dir. Names per the repo/KiroCrew
      # skill: pasta-backend = indexer daemon, kb = CLI, kb-mcp = MCP stdio
      # server (spawned by the gateway; see the mcp.json service below).
      for b in pasta-backend kb kb-mcp; do
        if [ -x "$CARGO_TARGET_DIR/release/$b" ]; then
          ln -sfnT "$CARGO_TARGET_DIR/release/$b" "$binDir/$b"
          echo "linked $b -> $binDir/$b"
        else
          echo "warning: expected binary not built: $b" >&2
        fi
      done

      # Smoke test only — must never block startup. This binary revision does
      # not treat --version as print-and-exit; it starts up and blocks, so a
      # bare `... || true` cannot save us (the process never returns to let
      # `|| true` fire). Bound it with `timeout` so a hang can't stall the
      # unit's ExecStartPre until TimeoutStartSec (previously wedged the whole
      # nixos-rebuild for ~27min, then failed the switch with exit 4).
      timeout 5 "$binDir/pasta-backend" --version 2>/dev/null || true
      echo "pasta build complete"
    '';
  };

  # Grant the pasta user write access to the vault's .feeds/ directory only.
  # The daemon's fetch cycle calls write_feeds() to rewrite
  # ${vaultCheckout}/.feeds/{slack,gmail,linear,calendar}.md every cycle, but a
  # persisted `user:pasta:r-x` ACL (and its matching default) on that dir denies
  # the write, so the feed markdown never refreshes. This grants pasta rwX there
  # and sets a default ACL so files pasta creates stay writable. Scoped to
  # .feeds only — the rest of the vault stays read-only to pasta (it reads the
  # tree via the vault-readers group). Mirrors the setfacl cross-user pattern
  # used by obsidian-web-vault-grant and legacyKiroReadAccess. Idempotent.
  pastaFeedsWriteAccess = pkgs.writeShellApplication {
    name = "pasta-feeds-write-access";
    runtimeInputs = with pkgs; [
      acl
      coreutils
    ];
    text = ''
      set -euo pipefail
      feeds="${vaultCheckout}/.feeds"

      # The vault dir itself is 2750 kirocrew:vault-readers; pasta traverses and
      # reads it via the vault-readers group. Ensure the .feeds subdir exists and
      # is owned so the group (which pasta is in) can also write, then layer an
      # explicit ACL that overrides any stale user:pasta:r-x entry.
      install -d -o kirocrew -g vault-readers -m 2770 "$feeds"

      # Replace the restrictive entry: grant pasta rwX on the dir and default so
      # feed files pasta (re)writes inherit write permission for pasta.
      setfacl --modify user:pasta:rwX "$feeds"
      setfacl --modify default:user:pasta:rwX "$feeds"

      # Existing feed files may carry the old user:pasta:r-x from the default
      # ACL at creation time; re-grant on each so write_feeds can overwrite them.
      for f in "$feeds"/*.md; do
        [ -e "$f" ] || continue
        setfacl --modify user:pasta:rw- "$f"
      done

      echo "pasta-feeds-write-access complete"
    '';
  };
in
{
  systemd.services.pasta-feeds-write-access = {
    description = "Grant the pasta user write access to the vault .feeds directory";
    after = [ "kirocrew-vault-clone.service" ];
    requires = [ "kirocrew-vault-clone.service" ];
    before = [ "pasta-daemon.service" ];
    requiredBy = [ "pasta-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pastaFeedsWriteAccess}/bin/pasta-feeds-write-access";
      RemainAfterExit = true;
    };
  };

  # ── Pasta daemon ───────────────────────────────────────────────────────────
  # Builds pasta-backend from source (as an ExecStartPre) under the pasta
  # user's home, then runs it. Indexes the EC2 vault checkout read-only and
  # writes its index to ${pastaHome}/data. Slack credentials are provided by
  # sops through pasta-fetchers.env for its inline fetch cycle.
  systemd.services.pasta-daemon = {
    enable = true;
    description = "Pasta vault indexer";
    after = [
      "network-online.target"
      "kirocrew-vault-clone.service"
      "pasta-feeds-write-access.service"
      "sops-install-secrets.service"
    ];
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    requires = [ "kirocrew-vault-clone.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = hardening // {
      Type = "simple";
      User = "pasta";
      Group = "pasta";
      EnvironmentFile = [ "-/var/lib/pasta/secrets/pasta-fetchers.env" ];
      # Build/refresh pasta-backend from source before starting it. First build
      # on Graviton can take a while, hence the long TimeoutStartSec below.
      ExecStartPre = "${pastaSourceBuild}/bin/pasta-source-build";
      ExecStart = "${pastaHome}/bin/pasta-backend";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = "30min";
      WorkingDirectory = pastaHome;

      # ── systemd hardening ──────────────────────────────────────────────
      MemoryDenyWriteExecute = false; # Pasta may use JIT for search

      # Pasta reads the vault, writes only its own index state — plus the
      # vault's .feeds/ dir, which the daemon's fetch cycle rewrites via
      # write_feeds(). The vault stays read-only except for that one subdir:
      # systemd applies the most-specific path rule, so listing .feeds under
      # ReadWritePaths re-grants write to only it while the rest of the vault
      # remains read-only. The leading '-' makes it non-fatal if the dir is
      # absent (fresh box before the vault clone). The pasta user also needs a
      # filesystem-level ACL grant on this dir (pasta-feeds-write-access below),
      # since a persisted `user:pasta:r-x` ACL otherwise denies the write.
      ReadOnlyPaths = [
        vaultCheckout
      ];
      ReadWritePaths = [
        pastaHome
        "-${vaultCheckout}/.feeds"
      ];

      Environment = [
        "HOME=${pastaHome}"
        # Pasta resolves vault_path and [kb] data_dir from
        # ${pastaHome}/.pasta/config.toml (written by the build ExecStartPre).
        # These two are not read by the current binary's config path, but are
        # kept as documentation of the effective values.
        "PASTA_VAULT_PATH=${vaultCheckout}"
        "PASTA_DATA_DIR=${pastaDataDir}"
        # The daemon's feed cycle shells out to slack-api and linear-api.
        # Use the same packaged helper directory as pasta-fetch-external so
        # feed generation sees real remote data instead of silently returning
        # empty Slack/Linear results when the helpers are absent from PATH.
        "PATH=${pastaFetchBin}/bin:${pastaHome}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${pastaLibraryPath}"
        "PROTOC=${pkgs.protobuf}/bin/protoc"
        "PROTOC_INCLUDE=${pkgs.protobuf}/include"
      ];
    };
  };

  # ── Pasta vault indexer (periodic) ──────────────────────────────────────────
  # The pasta-daemon above provides the IPC socket and runs the credential-gated
  # fetch cycle (gmail/linear/slack/calendar) plus task housekeeping — but its
  # scheduler's fetch cycle deliberately EXCLUDES the `vault` source, so it never
  # refreshes the kb store that kb-mcp serves. On this host the vault is the only
  # source (the pasta user has no forge/messaging creds), so vault indexing must
  # be driven explicitly.
  #
  # `kb sync --source vault` fetches the vault checkout and indexes it into
  # ${pastaDataDir} (Parquet -> LanceDB + Tantivy) — the same store kb-mcp reads.
  # It is credential-free, idempotent ("No new records to sync" when current),
  # and safe to run on a timer. This keeps the gateway's knowledge base fresh as
  # the git-crypt vault sync lands new notes, with no manual step.
  systemd.services.pasta-vault-index = {
    description = "Index the vault into the pasta kb store (kb sync --source vault)";
    after = [
      "network-online.target"
      "kirocrew-vault-clone.service"
      "pasta-daemon.service"
      "ollama.service"
    ];
    wants = [
      "network-online.target"
      # Prefer the local embedder to be up so the embedding step succeeds;
      # `wants` (not `requires`) so a degraded Ollama still lets FTS indexing
      # run rather than blocking the vault index entirely.
      "ollama.service"
    ];
    # The kb binary is built/linked by pasta-daemon's ExecStartPre
    # (pasta-source-build). Require the daemon so ${pastaHome}/bin/kb exists and
    # the pinned ${pastaHome}/.pasta/config.toml has been written before we run.
    requires = [ "kirocrew-vault-clone.service" ];

    serviceConfig = hardening // {
      Type = "oneshot";
      User = "pasta";
      Group = "pasta";
      EnvironmentFile = [ "-/var/lib/pasta/secrets/pasta-fetchers.env" ];
      # Build/refresh the pasta binaries + pinned config first, so this unit is
      # self-sufficient even if it fires before pasta-daemon has started once
      # (e.g. right after boot, timer-triggered). Reuses the same builder.
      ExecStartPre = "${pastaSourceBuild}/bin/pasta-source-build";
      ExecStart = "${pastaHome}/bin/kb sync --source vault";
      TimeoutStartSec = "30min";
      WorkingDirectory = pastaHome;

      # ── systemd hardening (mirrors pasta-daemon) ───────────────────────
      MemoryDenyWriteExecute = false; # kb may use JIT for search/embedding

      # Reads the vault, writes only its own index state.
      ReadOnlyPaths = [ vaultCheckout ];
      ReadWritePaths = [ pastaHome ];

      Environment = [
        "HOME=${pastaHome}"
        "PASTA_VAULT_PATH=${vaultCheckout}"
        "PASTA_DATA_DIR=${pastaDataDir}"
        "PATH=${pastaHome}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${pastaLibraryPath}"
        "PROTOC=${pkgs.protobuf}/bin/protoc"
        "PROTOC_INCLUDE=${pkgs.protobuf}/include"
        "RUST_LOG=info"
      ];
    };
  };

  systemd.timers.pasta-vault-index = {
    description = "Periodically index the vault into the pasta kb store";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # First run shortly after boot, then every 15 minutes. Persistent catches
      # up one missed run after the host was stopped (matches the vault sync
      # cadence and keeps the kb store fresh without hammering the embedder).
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      Persistent = true;
      Unit = "pasta-vault-index.service";
    };
  };

  # ── Pasta external-source fetch (periodic) ──────────────────────────────────
  # Fetches the forge/messaging sources — slack, linear, gitlab (MRs), git
  # (commits) — into the same kb store the vault indexer writes, so the evidence
  # graph gains real cross-source edges (commit→Linear-issue references, MR↔issue
  # links, message mentions). Credentials come from sops (owned by pasta); the
  # ExecStartPre (pastaFetchSetup) materializes the token files, logs glab in,
  # and clones the git repos before the sync runs. Gmail/calendar are handled
  # separately (their gogcli keyring auth doesn't transplant to a headless box).
  systemd.services.pasta-fetch-external = {
    description = "Fetch external sources (slack/linear/gitlab/git) into the pasta kb store";
    after = [
      "network-online.target"
      "pasta-daemon.service"
      "ollama.service"
      "sops-install-secrets.service"
    ];
    wants = [
      "network-online.target"
      "ollama.service"
    ];
    # The kb binary + pinned config are produced by pasta-daemon's ExecStartPre.
    requires = [ "pasta-daemon.service" ];

    serviceConfig = hardening // {
      Type = "oneshot";
      User = "pasta";
      Group = "pasta";
      # Refresh binaries/config, then provision creds + repos, then sync.
      ExecStartPre = [
        "${pastaSourceBuild}/bin/pasta-source-build"
        "${pastaFetchSetup}/bin/pasta-fetch-setup"
      ];
      ExecStart = "${pastaHome}/bin/kb sync --source slack,linear,gitlab,git";
      TimeoutStartSec = "30min";
      WorkingDirectory = pastaHome;

      # ── systemd hardening (mirrors pasta-vault-index) ──────────────────
      MemoryDenyWriteExecute = false;

      # Writes its own index state + repo clones + token files, all under
      # ${pastaHome}. Reads the decrypted sops secrets from the same tree.
      ReadWritePaths = [ pastaHome ];

      # External fetch must reach the internet, but never IMDS.

      Environment = [
        "HOME=${pastaHome}"
        "PASTA_VAULT_PATH=${vaultCheckout}"
        "PASTA_DATA_DIR=${pastaDataDir}"
        # Helpers (slack-api/linear-api) + glab + git + system tools on PATH so
        # pasta's binary auto-detection and the git fetcher resolve them.
        "PATH=${pastaFetchBin}/bin:${pkgs.glab}/bin:${pkgs.git}/bin:${pastaHome}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${pastaLibraryPath}"
        "PROTOC=${pkgs.protobuf}/bin/protoc"
        "PROTOC_INCLUDE=${pkgs.protobuf}/include"
        "RUST_LOG=info"
      ];
    };
  };

  systemd.timers.pasta-fetch-external = {
    description = "Periodically fetch external sources into the pasta kb store";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Offset from the vault indexer (which runs at boot+5m/every 15m) so the
      # two don't contend for the embedder. Hourly matches the workstation's
      # per-source schedule cadence and respects API rate limits.
      OnBootSec = "12min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "pasta-fetch-external.service";
    };
  };
}
