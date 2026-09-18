{
  config,
  lib,
  pkgs,
  ...
}:

# NixOS module: system-level systemd services for the KiroCrew gateway and
# Pasta daemon, running under dedicated unprivileged identities.
#
# These replace the Home Manager user services (kirocrew-service.nix and
# pasta-service.nix) on headless/EC2 hosts. The Home Manager modules remain
# active on workstation profiles where everything runs under the operator user.
let
  kirocrewHome = "/var/lib/kirocrew";
  pastaHome = "/var/lib/pasta";

  # The kb store (LanceDB + Tantivy index). Written by the pasta indexer and
  # read by the kb-mcp server the gateway spawns. Group-readable via the
  # shared vault-readers group (see kirocrew-security.nix + tmpfiles below).
  pastaDataDir = "${pastaHome}/data";

  # Vault checkout location — kirocrew and pasta read via vault-readers group.
  vaultCheckout = "/var/lib/vault";

  # Shared code repository tree — kirocrew reads/writes via code-writers group
  # (see kirocrew-code.nix).
  codeCheckout = "/var/lib/code";

  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  # Source builder shared with the workstation profile (kirocrew-service.nix).
  # Pinned to the release in ../kirocrew-source-tag.nix — the same tag the
  # Home Manager outputs set via kirocrew.sourceTag — so this system service
  # and the operator profile never build different revisions. The gateway
  # service runs it as an ExecStartPre, then starts the freshly built venv, so
  # no restart wiring is needed here (systemd's own ExecStart picks it up).
  kirocrewSourceUpdate = import ../kirocrew-source-build.nix { inherit pkgs lib; } {
    pinnedSourceTag = import ../kirocrew-source-tag.nix;
  };

  # Absolute path to the source-built gateway under the kirocrew user's home.
  kirocrewSourceBin = "${kirocrewHome}/.local/share/kirocrew-source/current/.venv/bin/kirocrew";

  # Operator-facing `kirocrew` command.
  #
  # On this host the gateway runs as the dedicated kirocrew user and ALL of its
  # state — config, sessions, sockets — lives under ${kirocrewHome}. Nothing
  # installs the CLI for the operator (the Home Manager user service and its
  # source-update timer are workstation-only), so administering the box meant
  # becoming the kirocrew user by hand first.
  #
  # Merely putting the built binary on the operator's PATH would be worse than
  # missing: the CLI resolves its state from $HOME/$KIROCREW_HOME, so as `orre`
  # it would silently address a DIFFERENT, empty instance — `config get` would
  # read a config the gateway never sees. This wrapper re-enters as the kirocrew
  # user with the gateway's own environment, so it always reports the live
  # instance.
  #
  # Not a privilege grant: `orre` already holds passwordless sudo through wheel
  # (kirocrew-security.nix), while the kirocrew user has no sudo at all. This
  # only removes the `sudo -u kirocrew env HOME=... KIROCREW_HOME=...`
  # incantation. The setuid sudo from the system wrapper dir is required —
  # pkgs.sudo in a store path is not setuid.
  kirocrewCli = pkgs.writeShellApplication {
    name = "kirocrew";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      bin=${kirocrewSourceBin}
      if [ ! -x "$bin" ]; then
        echo "kirocrew is not built yet ($bin is missing)." >&2
        echo "The kirocrew-gateway service builds it on start; check:" >&2
        echo "  systemctl status kirocrew-gateway" >&2
        exit 1
      fi

      # The kirocrew user already IS the right identity with the right HOME, and
      # it has no sudo — so it must exec directly. root can too. Only the
      # operator needs to cross the identity boundary.
      case "$(id -un)" in
        kirocrew | root) exec "$bin" "$@" ;;
      esac

      # Set the environment with env(1) rather than `sudo VAR=val`: sudo only
      # accepts command-line variable assignments when sudoers grants SETENV,
      # so env keeps this working under the default env_reset policy.
      exec /run/wrappers/bin/sudo -u kirocrew -- env \
        HOME=${kirocrewHome} \
        KIROCREW_HOME=${kirocrewHome}/.kiro/crew \
        LD_LIBRARY_PATH=${kirocrewLibraryPath} \
        PATH=${kirocrewHome}/bin:${kirocrewHome}/.local/bin:/run/current-system/sw/bin \
        "$bin" "$@"
    '';
  };

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
  # ~/.config/<tool>-api/token.json, which the fetch unit reconstructs from sops.
  pastaSlackApi = pkgs.writeShellApplication {
    name = "slack-api";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec ${pkgs.python3}/bin/python3 ${./pasta-fetch-bin/slack-api} "$@"'';
  };
  pastaLinearApi = pkgs.writeShellApplication {
    name = "linear-api";
    runtimeInputs = [ pkgs.bash pkgs.curl pkgs.python3 ];
    text = ''exec ${pkgs.bash}/bin/bash ${./pasta-fetch-bin/linear-api} "$@"'';
  };
  # Directory placed on the fetch unit's PATH so pasta's binary auto-detection
  # (empty [binaries].slack_api/linear_api = "resolve from PATH") finds them.
  pastaFetchBin = pkgs.symlinkJoin {
    name = "pasta-fetch-bin";
    paths = [ pastaSlackApi pastaLinearApi ];
  };

  # Secret-dependent setup for the external fetch, run as an ExecStartPre of the
  # pasta-fetch-external unit (so it executes as the pasta user, which owns the
  # decrypted sops secrets). It (1) reconstructs the token.json files the helper
  # CLIs read, (2) logs glab in with the token for MR fetch, and (3) clones or
  # updates the git repos over HTTPS using the same token (no SSH key needed).
  # Idempotent: safe to run on every timer firing.
  pastaFetchSetup = pkgs.writeShellApplication {
    name = "pasta-fetch-setup";
    runtimeInputs = with pkgs; [ coreutils git glab jq ];
    text = ''
      set -euo pipefail
      secrets="${pastaHome}/secrets"
      home="${pastaHome}"

      # Ignore any user/system git url-rewrites (e.g. https->ssh insteadOf) and
      # never prompt for credentials, so the tokenized HTTPS clones can't be
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

      # ── slack + linear token files (mode 600, pasta-owned) ──────────────
      install -d -m 700 "$home/.config/slack-api" "$home/.config/linear-api"
      slack_token="$(cat "$secrets/slack-token")"
      linear_key="$(cat "$secrets/linear-api-key")"
      # slack-api expects {access_token, token_type} (static xoxp-, no refresh).
      jq -n --arg t "$slack_token" \
        '{access_token:$t, refresh_token:null, token_type:"user"}' \
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
      gl_token="$(cat "$secrets/gitlab-token")"
      auth="https://oauth2:$gl_token@gitlab.com"
      install -d -m 755 "$home/repos"
      clone_or_pull() {
        # $1 = local dir name, $2 = repo path on gitlab.com
        # Clone with history depth so pasta's `git log --since` fetcher sees more
        # than the latest commit (a --depth 1 clone yields only HEAD, starving
        # the git source). 500 commits covers the fetch window cheaply.
        local dir="$home/repos/$1" url="$auth/$2.git"
        if [ -d "$dir/.git" ]; then
          git -C "$dir" remote set-url origin "$url"
          git -C "$dir" fetch --depth 500 origin HEAD && \
            git -C "$dir" reset --hard FETCH_HEAD || \
            echo "warn: update $1 failed" >&2
        else
          git clone --depth 500 "$url" "$dir" || echo "warn: clone $1 failed" >&2
        fi
        # Scrub the tokenized URL from git config so the secret isn't persisted.
        git -C "$dir" remote set-url origin "https://gitlab.com/$2.git" 2>/dev/null || true
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
  pastaSourceBuild = pkgs.writeShellApplication {
    name = "pasta-source-build";
    runtimeInputs = with pkgs; [
      coreutils
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
        git clone --depth 1 https://github.com/orriborri/pasta.git "$srcRoot"
      else
        git -C "$srcRoot" fetch --depth 1 origin HEAD
        git -C "$srcRoot" reset --hard FETCH_HEAD
      fi

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

  # CFM Tips MCP server builder — an ExecStartPre of the gateway (runs as the
  # kirocrew user, inside the gateway's sandbox). Clones the pinned aws-samples
  # checkout and builds a self-contained venv the gateway's mcp.json spawns as
  # a stdio MCP server. Everything lives under ${kirocrewHome}/cfm-tips, which
  # is already the gateway unit's single ReadWritePath.
  #
  # Pinned to an immutable SHA (repos.toml carries the same one for the human
  # checkout): this server is handed read-only AWS cost/resource credentials,
  # so it must not silently follow a moving branch.
  #
  # python312, NOT the nixpkgs default python3 (3.14): this AWS-samples repo
  # targets 3.11+ and is not tested against 3.14. Wheels for the deps
  # (boto3/botocore/psutil/mcp) are pulled from PyPI; `mcp` is installed
  # explicitly because the repo's requirements.txt omits it even though the
  # server imports mcp.server/.stdio/.types. gcc + the interpreter's dev
  # headers are on PATH so a dep with no aarch64 wheel (this is a Graviton
  # t4g box) falls back to a source build instead of failing the unit.
  cfmTipsPython = pkgs.python312;
  cfmTipsRev = "dcf19f1ed6905bc0c9f556ac28a1d33dd7128a67";
  cfmTipsDir = "${kirocrewHome}/cfm-tips";
  cfmTipsServerBin = "${cfmTipsDir}/.venv/bin/python";
  cfmTipsServerScript = "${cfmTipsDir}/src/mcp_server_with_runbooks.py";
  # Region the cost server queries. Matches the launcher's DEFAULT_REGION
  # (kirocrew_ec2/models.py). Cost Explorer is global, but boto3 still needs a
  # region set; several playbooks (EC2/EBS/RDS describes) are regional.
  cfmTipsAwsRegion = "eu-central-1";
  cfmTipsSourceBuild = pkgs.writeShellApplication {
    name = "cfm-tips-source-build";
    runtimeInputs = with pkgs; [
      coreutils
      git
      cfmTipsPython
      gcc # source-build fallback for any dep without an aarch64 wheel
      gnumake
    ];
    text = ''
      srcRoot="${cfmTipsDir}/src"
      venv="${cfmTipsDir}/.venv"
      export PIP_CACHE_DIR="${cfmTipsDir}/.pip-cache"

      # Public, read-only checkout: ignore user Git URL rewrites so an HTTPS
      # clone can't be redirected to an SSH clone needing credentials.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0

      mkdir -p "$srcRoot" "$PIP_CACHE_DIR"

      # Clone once, then pin to the exact revision. Fetch the specific SHA so a
      # shallow clone can still check it out (a bare --depth 1 clone only has
      # the branch tip).
      if [ ! -d "$srcRoot/.git" ]; then
        git clone --filter=blob:none https://github.com/aws-samples/sample-cfm-tips-mcp.git "$srcRoot"
      fi
      git -C "$srcRoot" fetch --depth 1 origin "${cfmTipsRev}"
      git -C "$srcRoot" checkout --quiet --detach "${cfmTipsRev}"

      # (Re)build the venv only when the interpreter or the pin changed. A
      # stamp file records the revision the current venv was built against.
      stamp="$venv/.cfm-tips-rev"
      if [ ! -x "${cfmTipsServerBin}" ] || [ "$(cat "$stamp" 2>/dev/null || true)" != "${cfmTipsRev}" ]; then
        echo "Building CFM Tips venv (${cfmTipsRev})..."
        rm -rf "$venv"
        ${cfmTipsPython}/bin/python3 -m venv "$venv"
        "$venv/bin/pip" install --upgrade pip
        # requirements.txt omits mcp (the server imports it) — add it explicitly.
        "$venv/bin/pip" install -r "$srcRoot/requirements.txt" mcp
        echo "${cfmTipsRev}" > "$stamp"
      fi

      # Smoke test: the module must import (proves boto3 + mcp resolved). Bounded
      # by timeout and non-fatal so a transient import hiccup can't wedge the
      # gateway's startup — the dashboard MCP probe is the real health signal.
      timeout 30 "$venv/bin/python" -c "import boto3, mcp" 2>/dev/null \
        || echo "warning: cfm-tips venv import smoke test failed" >&2
      echo "cfm-tips build complete"
    '';
  };

  # MCP wiring for the gateway. Writes the gateway's mcp.json (which spawns the
  # kb-mcp stdio server built by the pasta-daemon) and the kirocrew user's
  # pasta config so kb-mcp resolves the SAME data_dir as the indexer. Runs as
  # kirocrew so file ownership matches the gateway. Idempotent: overwrites both
  # files each start so config drift can't accumulate.
  kirocrewMcpConfig = pkgs.writeShellApplication {
    name = "kirocrew-mcp-config";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      crewDir="${kirocrewHome}/.kiro/crew"
      pastaCfgDir="${kirocrewHome}/.pasta"
      mkdir -p "$crewDir" "$pastaCfgDir"

      # kb-mcp resolves [kb] data_dir from $HOME/.pasta/config.toml. The gateway
      # spawns kb-mcp with HOME=${kirocrewHome}, so this file must point at the
      # shared store the pasta indexer writes.
      cat > "$pastaCfgDir/config.toml" <<EOF
      [general]
      vault_path = "${vaultCheckout}"
      log_level = "info"

      [kb]
      data_dir = "${pastaDataDir}"
      EOF


      # Gateway MCP registry. kb-evidence spawns the locally-built kb-mcp stdio
      # server (linked into ${pastaHome}/bin by the pasta-daemon build step).
      # cfm-tips spawns the aws-samples cost-optimization server from the venv
      # built by cfm-tips-source-build (an ExecStartPre above). Its AWS creds
      # come from the gateway environment as ''${env:...} references, which
      # KiroCrew resolves at session runtime (see kirocrew-services env +
      # SOPS). They are written LITERALLY here — the \$ stops both Nix
      # interpolation and this bash heredoc from expanding them, so the token
      # reaches mcp.json intact for KiroCrew to resolve.
      cat > "$crewDir/mcp.json" <<EOF
      {
        "mcpServers": {
          "kb-evidence": {
            "command": "${pastaHome}/bin/kb-mcp",
            "args": [],
            "env": {
              "HOME": "${kirocrewHome}",
              "RUST_LOG": "error"
            },
            "disabled": false
          },
          "cfm-tips": {
            "command": "${cfmTipsServerBin}",
            "args": ["${cfmTipsServerScript}"],
            "env": {
              "HOME": "${kirocrewHome}",
              "AWS_REGION": "${cfmTipsAwsRegion}",
              "AWS_DEFAULT_REGION": "${cfmTipsAwsRegion}",
              "AWS_ACCESS_KEY_ID": "\''${env:CFM_TIPS_AWS_ACCESS_KEY_ID}",
              "AWS_SECRET_ACCESS_KEY": "\''${env:CFM_TIPS_AWS_SECRET_ACCESS_KEY}"
            },
            "disabled": false
          }
        }
      }
      EOF
      echo "wrote $crewDir/mcp.json and $pastaCfgDir/config.toml"
    '';
  };

  legacyKiroReadAccess = pkgs.writeShellApplication {
    name = "kirocrew-legacy-kiro-read-access";
    runtimeInputs = with pkgs; [
      acl
      findutils
    ];
    text = ''
      set -euo pipefail
      legacy_dir=/home/orre/.kiro
      if [[ ! -d "$legacy_dir" ]]; then
        echo "Legacy Kiro directory is absent; nothing to expose."
        exit 0
      fi

      # /home/orre is 0700, so grant kirocrew traverse-only (no read) on the
      # home directory itself. This lets the ACL below on .kiro be reachable
      # without exposing the rest of the operator's home to the group/others.
      setfacl --modify user:kirocrew:--x /home/orre

      # Existing entries need an access ACL, while defaults ensure newly
      # created historical state remains readable. No write permission is
      # granted; the gateway also receives a read-only bind in its namespace.
      setfacl --recursive --modify user:kirocrew:r-X "$legacy_dir"
      find "$legacy_dir" -type d \
        -exec setfacl --modify default:user:kirocrew:r-X {} +
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
  # Operator `kirocrew` command (wrapper above). Lands at
  # /run/current-system/sw/bin/kirocrew. It does not shadow the kirocrew user's
  # own CLI: that user's PATH puts ${kirocrewHome}/.local/bin first, and the
  # wrapper execs the real binary directly for kirocrew and root anyway.
  environment.systemPackages = [ kirocrewCli ];

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

  systemd.services.kirocrew-legacy-kiro-read-access = {
    description = "Grant KiroCrew read-only access to the operator's legacy Kiro state";
    before = [ "kirocrew-gateway.service" ];
    requiredBy = [ "kirocrew-gateway.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${legacyKiroReadAccess}/bin/kirocrew-legacy-kiro-read-access";
      RemainAfterExit = true;
    };
  };

  systemd.services.kirocrew-mcp-config = {
    description = "Write the KiroCrew gateway MCP config (kb-evidence → kb-mcp)";
    before = [ "kirocrew-gateway.service" ];
    requiredBy = [ "kirocrew-gateway.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kirocrew";
      Group = "kirocrew";
      ExecStart = "${kirocrewMcpConfig}/bin/kirocrew-mcp-config";
      RemainAfterExit = true;
    };
  };

  # ── KiroCrew gateway ───────────────────────────────────────────────────────
  systemd.services.kirocrew-gateway = {
    description = "KiroCrew Gateway";
    after = [
      "network-online.target"
      "kirocrew-legacy-kiro-read-access.service"
      "kirocrew-mcp-config.service"
      "kirocrew-vault-clone.service"
      # Ordering only (no requires): the cfm-tips EnvironmentFile is rendered by
      # sops-install-secrets. Non-fatal — the '-' EnvironmentFile above and the
      # server's own disabled-until-creds behaviour tolerate its absence.
      "sops-install-secrets.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "kirocrew-legacy-kiro-read-access.service"
      "kirocrew-mcp-config.service"
      "kirocrew-vault-clone.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "kirocrew";
      Group = "kirocrew";
      ExecStart = "${kirocrewSourceBin} gateway";
      Restart = "always";
      RestartSec = 5;
      TimeoutStartSec = "20min";
      WorkingDirectory = kirocrewHome;

      # ── Sandbox: auto mode ─────────────────────────────────────────────
      # KiroCrew v0.5.0 retired the 'strict' value for agent.sandbox; the
      # allowed values are now 'auto' and 'off'. 'auto' turns the namespace
      # sandbox on automatically, providing the isolation the systemd hardening
      # below is tuned for (see the NoNewPrivileges / RestrictNamespaces notes).
      # systemd hardening adds defense in depth at the service level.
      ExecStartPre = [
        # Build/update the gateway from source (newest stable tag), producing
        # ${kirocrewHome}/.local/share/kirocrew-source/current/.venv/bin/kirocrew.
        # First build compiles the dashboard + Python venv, hence the long
        # TimeoutStartSec above.
        "${kirocrewSourceUpdate}/bin/kirocrew-source-update"
        # Build/update the CFM Tips MCP server venv (aws-samples cost tooling)
        # before the gateway starts, so the mcp.json entry below has a working
        # interpreter to spawn. Non-fatal: a '-' prefix keeps a transient PyPI
        # or build failure from blocking the whole gateway — the server simply
        # probes unhealthy in the dashboard until the next start rebuilds it.
        "-${cfmTipsSourceBuild}/bin/cfm-tips-source-build"
        "${pkgs.coreutils}/bin/mkdir -p ${kirocrewHome}/.kiro/crew"
        # Existing generated agent specs can retain the legacy installer path
        # ~/.kiro/crew-venv/bin/kirocrew even after the gateway moved to the
        # source-built release. That venv is 0.4.1rc1 here while the gateway is
        # 0.7.0rc1. Since #8467, session_pid_<pid>.txt is a TWO-line record
        # (<session-key> + process start token); the old MCP reader treats the
        # whole file as the HTTP session header and produces an illegal embedded
        # newline. Keep the stable legacy entrypoint but point it at the exact
        # source-built CLI the gateway runs, so stale specs and fresh specs share
        # one parser/identity contract. mkdir makes this safe on source-only
        # installs where the legacy venv never existed.
        "${pkgs.coreutils}/bin/mkdir -p ${kirocrewHome}/.kiro/crew-venv/bin"
        "${pkgs.coreutils}/bin/ln -sfnT ${kirocrewSourceBin} ${kirocrewHome}/.kiro/crew-venv/bin/kirocrew"
        "${kirocrewSourceBin} config set --local agent.sandbox auto"
        # v0.7 defaults member chats to the KAS/v3 backend. The system nixpkgs
        # pin currently provides kiro-cli 2.18.1, whose `acp` parser accepts
        # `--agent-engine v3` but NOT the `--auth-method cli` argument KAS adds;
        # every member (observed first on kirocrew-research) therefore dies at
        # startup with rc=2. Keep members on the compatible kiro/v2 backend
        # until the package pin is upgraded to a CLI that supports that flag.
        # This is a hard compatibility gate, not a preference: if the setting
        # cannot be asserted, starting a gateway whose member processes all
        # crash would be a false-success boot.
        "${kirocrewSourceBin} config set --local agent.member_acp_backend kiro"
        # v0.6.0 introduced a two-hour ceiling on unattended auto-run plans
        # (orchestrator.max_plan_duration_seconds, default 7200). This host runs
        # long-horizon unattended work — the conductor and heartbeat agents — so
        # the stock ceiling silently cuts a plan mid-flight. Raised to 8h, which
        # keeps a runaway backstop; 0 would remove the ceiling entirely. A
        # stage-gated plan is never cut regardless.
        # The `-` prefix makes these non-fatal. Every ExecStartPre is otherwise a
        # hard gate on the gateway starting, and `config set` exits non-zero on a
        # key this build does not know — so an upstream rename would stop the
        # gateway booting rather than merely skipping a preference. v0.6.0
        # retiring the `strict` value for agent.sandbox is exactly that shape of
        # change. These four are operational preferences, so degrade to the
        # build's own default instead of wedging the service. The agent.sandbox
        # line above deliberately keeps NO `-`: if the sandbox posture cannot be
        # asserted, failing closed is correct.
        "-${kirocrewSourceBin} config set --local orchestrator.max_plan_duration_seconds 28800"
        # Session summaries: an intent-level "why / what happened / what next"
        # panel that makes re-entering a session cheap for a HUMAN. It does not
        # shrink agent context — it costs an extra model call at turn end, which
        # is why upstream ships it off. regenerate_after_turns is raised from 1
        # (every turn) to 50 so unattended sessions nobody reads don't pay per
        # turn: one summary generates early, and an explicit on-demand refresh
        # bypasses the cadence gate. Enabling is required even for that
        # on-demand pass — `force` does not lift the `disabled` gate.
        "-${kirocrewSourceBin} config set --local session_summary.enabled true"
        "-${kirocrewSourceBin} config set --local session_summary.regenerate_after_turns 50"
        # Per-turn tokens, spend and latency across cron, heartbeat, subagents,
        # workflows and channels — the cheapest way to see what the unattended
        # agents on this host actually cost. Local JSONL sink; OTLP egress stays
        # opt-in behind the separate `otlp` extra. telemetry.beacon_enabled (the
        # phone-home) is deliberately NOT set and remains off.
        "-${kirocrewSourceBin} config set --local telemetry.enabled true"
      ];

      # ── systemd hardening ──────────────────────────────────────────────
      # NoNewPrivileges MUST stay off: KiroCrew's namespace sandbox runs the agent
      # (kiro-cli via ACP) inside an unprivileged user+mount namespace and seals
      # paths like ${kirocrewHome}/.kiro/crew/run read-only via remount. With
      # NoNewPrivileges=yes the process cannot gain the privileges that remount
      # needs inside the userns, so the seal fails with EPERM and every agent
      # session/cron dies with AcpRuntimeDead. The kernel already allows
      # unprivileged userns (user.max_user_namespaces > 0) and the kirocrew user
      # can perform the seal by hand, so the namespace sandbox remains the real
      # isolation layer; this only removes the redundant systemd flag that blocks
      # it. RestrictNamespaces is already false for the same reason.
      NoNewPrivileges = false;
      ProtectSystem = "strict";
      # Hide all operator homes, then selectively expose the legacy Kiro tree
      # at its original path through a read-only bind. ACLs from the prerequisite
      # service provide file-level read permission without granting writes.
      ProtectHome = "tmpfs";
      BindReadOnlyPaths = [ "/home/orre/.kiro" ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = false; # KiroCrew strict sandbox needs namespaces
      LockPersonality = true;
      MemoryDenyWriteExecute = false; # Node.js JIT needs W+X

      # Repositories and the vault are both writable agent workspaces now. The
      # vault is a git-crypt checkout owned by kirocrew (see
      # kirocrew-vault-git.nix); the agent edits notes in place and the
      # vault-sync service commits, reconciles, and pushes them.
      ReadWritePaths = [
        kirocrewHome
        codeCheckout
        vaultCheckout
        "/tmp"
      ];

      # Keep git internals and index/state read-only to the agent even though
      # note content is writable. A leading '-' makes absent paths non-fatal.
      ReadOnlyPaths = [
        "-${vaultCheckout}/.git"
        "-${vaultCheckout}/.obsidian"
        "-${vaultCheckout}/.lancedb"
        "-${vaultCheckout}/.semantic_search"
        # Pasta's kb store: the gateway spawns kb-mcp (as the kirocrew user),
        # which reads this index. Group read access comes from the shared
        # vault-readers group; ProtectSystem=strict still needs the path
        # exposed read-only into the gateway's mount namespace.
        "-${pastaDataDir}"
      ];

      # Block IMDS access from agents.
      IPAddressDeny = [ "169.254.169.254/32" ];

      # Read-only AWS creds for the cfm-tips MCP server, composed by the sops
      # template (kirocrew-sops.nix) into KEY=value lines. The leading '-' makes
      # it non-fatal when absent (a box without the CFM Tips secrets still
      # boots; the server just gets no creds and its tools error until set).
      EnvironmentFile = [ "-/var/lib/kirocrew/secrets/cfm-tips-aws.env" ];

      Environment = [
        "KIROCREW_HOME=${kirocrewHome}/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "HOME=${kirocrewHome}"
        "TMPDIR=/tmp/kirocrew"
        "PATH=${kirocrewHome}/bin:${kirocrewHome}/.local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${kirocrewLibraryPath}"
        # Pin npm/npx entirely inside the kirocrew home. The agent runs MCP
        # servers via `npx -y mcp-remote …` (metabase, linear). Without these,
        # npm resolves its cache/user-config/prefix relative to $HOME *and* the
        # process cwd — and if a runtime is ever spawned with cwd under another
        # user's home (e.g. /home/orre, mode 0700), npm's attempt to read that
        # dir's .npmrc and `spawn sh` there fails with EACCES and the MCP server
        # dies with "connection closed: initialize response", taking chat down.
        # Anchoring all three to ${kirocrewHome} makes `npx` cwd-independent and
        # keeps every npm write inside the one ReadWritePath the unit owns.
        "NPM_CONFIG_CACHE=${kirocrewHome}/.npm"
        "NPM_CONFIG_USERCONFIG=${kirocrewHome}/.npmrc"
        "NPM_CONFIG_PREFIX=${kirocrewHome}/.npm-global"
        "KIROCREW_BIND=127.0.0.1"
        "KIROCREW_DEVFLEET_BIN_GIT=${pkgs.git}/bin/git"
        # 1Password agent socket, relayed from the operator's forwarded socket
        # while the launcher portal session is open. Absent otherwise, so the
        # agent can push to git ONLY while the operator is online (and each
        # signature is gated by a 1Password approval prompt).
        "SSH_AUTH_SOCK=/run/kirocrew/1p-agent.sock"
      ];
    };
  };

  # ── Pasta daemon ───────────────────────────────────────────────────────────
  # Builds pasta-backend from source (as an ExecStartPre) under the pasta
  # user's home, then runs it. Indexes the EC2 vault checkout read-only and
  # writes its index to ${pastaHome}/data.
  systemd.services.pasta-daemon = {
    enable = true;
    description = "Pasta vault indexer";
    after = [
      "network-online.target"
      "kirocrew-vault-clone.service"
      "pasta-feeds-write-access.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "kirocrew-vault-clone.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "pasta";
      Group = "pasta";
      # Build/refresh pasta-backend from source before starting it. First build
      # on Graviton can take a while, hence the long TimeoutStartSec below.
      ExecStartPre = "${pastaSourceBuild}/bin/pasta-source-build";
      ExecStart = "${pastaHome}/bin/pasta-backend";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = "30min";
      WorkingDirectory = pastaHome;

      # ── systemd hardening ──────────────────────────────────────────────
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
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

      # Block IMDS.
      IPAddressDeny = [ "169.254.169.254/32" ];

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

    serviceConfig = {
      Type = "oneshot";
      User = "pasta";
      Group = "pasta";
      # Build/refresh the pasta binaries + pinned config first, so this unit is
      # self-sufficient even if it fires before pasta-daemon has started once
      # (e.g. right after boot, timer-triggered). Reuses the same builder.
      ExecStartPre = "${pastaSourceBuild}/bin/pasta-source-build";
      ExecStart = "${pastaHome}/bin/kb sync --source vault";
      TimeoutStartSec = "30min";
      WorkingDirectory = pastaHome;

      # ── systemd hardening (mirrors pasta-daemon) ───────────────────────
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = false; # kb may use JIT for search/embedding

      # Reads the vault, writes only its own index state.
      ReadOnlyPaths = [ vaultCheckout ];
      ReadWritePaths = [ pastaHome ];

      # Block IMDS.
      IPAddressDeny = [ "169.254.169.254/32" ];

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

    serviceConfig = {
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
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = false;

      # Writes its own index state + repo clones + token files, all under
      # ${pastaHome}. Reads the decrypted sops secrets from the same tree.
      ReadWritePaths = [ pastaHome ];

      # External fetch must reach the internet, but never IMDS.
      IPAddressDeny = [ "169.254.169.254/32" ];

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

  # ── 1Password agent socket bridge ──────────────────────────────────────────
  # The launcher (`launch-ec2 portal`) forwards the operator's local 1Password
  # agent socket to /run/kirocrew-agent/orre-1p.sock (owned by orre, created by
  # sshd's -R). That socket is not readable by the kirocrew service user, so a
  # socat relay re-exposes it at /run/kirocrew/1p-agent.sock with group kirocrew
  # (0660). The gateway unit references the latter via SSH_AUTH_SOCK.
  #
  # The relay is PATH-ACTIVATED on the forwarded socket: systemd starts it the
  # moment the portal session creates the socket. It must ALSO stop when the
  # portal closes and sshd unlinks the socket — but a systemd `PathExists=` path
  # unit only *activates* its unit on existence; it does NOT stop the unit when
  # the path disappears (see systemd.path(5)). A bare `socat ...,fork` listener
  # would therefore linger and keep re-exposing the (now dangling) bridge to the
  # gateway after the operator is gone.
  #
  # So the relay watches the forwarded socket itself and exits as soon as it
  # disappears. `socat` runs in the background; a small poll loop tears the whole
  # service down when /run/kirocrew-agent/orre-1p.sock is gone, which triggers
  # ExecStopPost to remove the relayed socket. Result: the git-push bridge exists
  # only while the portal session holds the forwarded socket open.
  systemd.paths.kirocrew-1p-agent-relay = {
    description = "Watch for the operator's forwarded 1Password socket";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/run/kirocrew-agent/orre-1p.sock";
      Unit = "kirocrew-1p-agent-relay.service";
    };
  };

  systemd.services.kirocrew-1p-agent-relay = {
    description = "Relay the operator's 1Password agent socket to the kirocrew gateway";
    serviceConfig = {
      Type = "simple";
      # Relay must be able to create a socket owned by the kirocrew group and
      # connect to the orre-owned forwarded socket; run as root, drop the new
      # socket into the kirocrew group at 0660. Bound to the forwarded socket's
      # existence: when the operator's portal session ends and sshd unlinks
      # /run/kirocrew-agent/orre-1p.sock, the watcher stops socat so the bridge
      # cannot outlive the session.
      ExecStart = pkgs.writeShellScript "kirocrew-1p-agent-relay" ''
        set -eu
        upstream=/run/kirocrew-agent/orre-1p.sock
        listen=/run/kirocrew/1p-agent.sock
        ${pkgs.socat}/bin/socat \
          "UNIX-LISTEN:$listen,fork,mode=0660,user=kirocrew,group=kirocrew" \
          "UNIX-CONNECT:$upstream" &
        socat_pid=$!
        cleanup() { kill "$socat_pid" 2>/dev/null || true; }
        trap cleanup EXIT INT TERM
        # Exit (and let ExecStopPost remove the relayed socket) the moment the
        # forwarded upstream socket disappears, i.e. when the portal closes.
        while [ -S "$upstream" ] && kill -0 "$socat_pid" 2>/dev/null; do
          sleep 1
        done
      '';
      Restart = "on-failure";
      RestartSec = 2;
      # Clean up the relayed socket when the forward goes away.
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f /run/kirocrew/1p-agent.sock";
    };
  };

  # ── Ensure kirocrew tmp + socket-bridge directories ────────────────────────
  # /run/kirocrew-agent: where sshd binds the operator's forwarded socket
  #   (must be writable by orre so the -R forward can create the socket).
  # /run/kirocrew: where the relay exposes the socket to the gateway.
  systemd.tmpfiles.rules = [
    "d /tmp/kirocrew 0700 kirocrew kirocrew -"
    "d /run/kirocrew-agent 0750 orre kirocrew -"
    "d /run/kirocrew 0750 kirocrew kirocrew -"
    # Pasta build/runtime dirs (pasta user owns its home tree). The build
    # script also mkdir -p's these, but declaring them guarantees ownership
    # and that PASTA_DATA_DIR exists before the daemon starts. The data dir is
    # group-owned by vault-readers and setgid (2750) so the index files the
    # pasta user writes are readable by the kirocrew gateway (which spawns
    # kb-mcp), and new files inherit the group.
    "d ${pastaHome}/bin 0755 pasta pasta -"
    "d ${pastaDataDir} 2750 pasta vault-readers -"
    # KiroCrew skill files (synced from managed skill checkouts by
    # kirocrew-skill-sync.service in kirocrew-code.nix).
    "d ${kirocrewHome}/.kiro/crew/skills 0755 kirocrew kirocrew -"
  ];
}
