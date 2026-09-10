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
  # Follows the newest stable tag (pinnedSourceTag = ""). The gateway service
  # runs it as an ExecStartPre, then starts the freshly built venv, so no
  # restart wiring is needed here (systemd's own ExecStart picks it up).
  kirocrewSourceUpdate = import ../kirocrew-source-build.nix { inherit pkgs lib; } {
    pinnedSourceTag = "";
  };

  # Absolute path to the source-built gateway under the kirocrew user's home.
  kirocrewSourceBin = "${kirocrewHome}/.local/share/kirocrew-source/current/.venv/bin/kirocrew";

  pastaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];

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
in
{
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
        "${pkgs.coreutils}/bin/mkdir -p ${kirocrewHome}/.kiro/crew"
        "${kirocrewSourceBin} config set --local agent.sandbox auto"
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
      # vault-push service commits and pushes them.
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

      Environment = [
        "KIROCREW_HOME=${kirocrewHome}/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "HOME=${kirocrewHome}"
        "TMPDIR=/tmp/kirocrew"
        "PATH=${kirocrewHome}/bin:${kirocrewHome}/.local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${kirocrewLibraryPath}"
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

      # Pasta reads the vault, writes only its own index state.
      ReadOnlyPaths = [
        vaultCheckout
      ];
      ReadWritePaths = [
        pastaHome
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
        "PATH=${pastaHome}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${pastaLibraryPath}"
        "PROTOC=${pkgs.protobuf}/bin/protoc"
        "PROTOC_INCLUDE=${pkgs.protobuf}/include"
      ];
    };
  };

  # ── 1Password agent socket bridge ──────────────────────────────────────────
  # The launcher (`launch-ec2 portal`) forwards the operator's local 1Password
  # agent socket to /run/kirocrew-agent/orre-1p.sock (owned by orre, created by
  # sshd's -R). That socket is not readable by the kirocrew service user, so a
  # socat relay re-exposes it at /run/kirocrew/1p-agent.sock with group kirocrew
  # (0660). The gateway unit references the latter via SSH_AUTH_SOCK.
  #
  # The relay is PATH-ACTIVATED on the forwarded socket: it runs only while the
  # portal session holds the socket open, so the gateway can push to git ONLY
  # while the operator is online. When the portal closes, sshd unlinks the
  # socket, the path unit stops the relay, and the bridge disappears.
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
      # socket into the kirocrew group at 0660.
      ExecStart =
        "${pkgs.socat}/bin/socat "
        + "UNIX-LISTEN:/run/kirocrew/1p-agent.sock,fork,mode=0660,user=kirocrew,group=kirocrew "
        + "UNIX-CONNECT:/run/kirocrew-agent/orre-1p.sock";
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
