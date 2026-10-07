{ lib, pkgs, ... }:

# NixOS module: the KiroCrew gateway as a system service under the dedicated
# unprivileged kirocrew user, with the oneshots it requires (legacy Kiro
# read ACL, mcp.json writer) and the crew registration unit. Split out of
# kirocrew-services.nix, which keeps the operator CLI wrapper and the
# tmpfiles rules; pasta.nix, kirocrew-mcp-servers.nix and
# kirocrew-1p-relay.nix hold the rest of the former file.
#
# Replaces the Home Manager user service (kirocrew-service.nix) on
# headless/EC2 hosts. The Home Manager module remains active on workstation
# profiles where everything runs under the operator user.
let
  hardening = import ./kirocrew-hardening.nix;
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

  # KiroCrew's Claude/Codex harnesses are ACP npm adapters, separate from the
  # claude-code and codex CLI packages. Install them in the dedicated user's
  # private npm prefix so the Developer -> Agent Backend probes can find them.
  # Agent backends installed globally for the kirocrew user. Exact versions;
  # find newer ones with `npm view <package> version`.
  claudeAcpVersion = "0.86.0";
  codexAcpVersion = "2.1.1";

  kirocrewAgentBackends = pkgs.writeShellScript "kirocrew-agent-backends" ''
    set -eu
    export HOME=${kirocrewHome}
    export PATH=${kirocrewHome}/.npm-global/bin:${pkgs.nodejs_22}/bin:${kirocrewHome}/bin:/run/current-system/sw/bin
    export NPM_CONFIG_PREFIX=${kirocrewHome}/.npm-global
    export NPM_CONFIG_CACHE=${kirocrewHome}/.npm
    export NPM_CONFIG_USERCONFIG=${kirocrewHome}/.npmrc
    install -d -m 0750 ${kirocrewHome}/.npm-global ${kirocrewHome}/.npm
    # Install exact versions, and reinstall when the installed one differs, so
    # bumping a version below takes effect and nothing floats to "latest".
    install_acp() {
      pkg=$1
      want=$2
      have=$(${pkgs.nodejs_22}/bin/node -p \
        "try{require('${kirocrewHome}/.npm-global/lib/node_modules/$pkg/package.json').version}catch(e){'''}")
      [ "$have" = "$want" ] || ${pkgs.nodejs_22}/bin/npm install --global "$pkg@$want"
    }
    install_acp @agentclientprotocol/claude-agent-acp ${claudeAcpVersion}
    install_acp @agentclientprotocol/codex-acp ${codexAcpVersion}
  '';

  # MCP server builders, launchers and the mcp.json writer (ExecStartPre
  # steps of the gateway and the kirocrew-mcp-config unit below).
  mcpServers = import ./kirocrew-mcp-servers.nix {
    inherit
      pkgs
      kirocrewHome
      pastaHome
      pastaDataDir
      vaultCheckout
      ;
  };
  inherit (mcpServers) cfmTipsSourceBuild slackMcpSourceBuild kirocrewMcpConfig;

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
  # Registers the agent crews (specs are installed by the kirocrew-review-agents,
  # -dev-crew and -assistant activation scripts, each of which adds its own
  # ExecStart here). Ordered after the gateway because its ExecStartPre creates
  # the crew-venv symlink the CLI is run through. Restarted on `switch` whenever
  # a script changes; registration is idempotent.
  systemd.services.kirocrew-register-agents = {
    description = "Register KiroCrew agent crews";
    after = [ "kirocrew-gateway.service" ];
    wants = [ "kirocrew-gateway.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  systemd.services.kirocrew-gateway = {
    description = "KiroCrew Gateway";
    after = [
      "network-online.target"
      "kirocrew-legacy-kiro-read-access.service"
      "kirocrew-mcp-config.service"
      "kirocrew-vault-clone.service"
      # Ordering only (no requires): the MCP launchers read secret files that
      # sops-install-secrets writes. Non-fatal: the launchers start their
      # servers without credentials when the files are absent.
      "sops-install-secrets.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "kirocrew-legacy-kiro-read-access.service"
      "kirocrew-mcp-config.service"
      "kirocrew-vault-clone.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = hardening // {
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
        "${kirocrewAgentBackends}"
        # Build/update the CFM Tips MCP server venv (aws-samples cost tooling)
        # before the gateway starts, so the mcp.json entry below has a working
        # interpreter to spawn. Non-fatal: a '-' prefix keeps a transient PyPI
        # or build failure from blocking the whole gateway — the server simply
        # probes unhealthy in the dashboard until the next start rebuilds it.
        "-${cfmTipsSourceBuild}/bin/cfm-tips-source-build"
        # Build/update the Slack MCP server venv before the gateway starts, so
        # the mcp.json `slack` entry has a working interpreter to spawn.
        # Non-fatal ('-'): a transient PyPI/build failure just leaves the Slack
        # server probing unhealthy until the next start rebuilds it.
        "-${slackMcpSourceBuild}/bin/kirocrew-slack-mcp-build"
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

      # Memory: the gateway has peaked above 13G under concurrent member load
      # and crash-looped when the box ran out. Throttle and reclaim above 70%
      # of RAM, hard-cap at 85% so the rest of the host survives, and let the
      # OOM killer take a single agent process without stopping the gateway.
      # Percentages, because the instance type has varied (16G and 30G).
      MemoryHigh = "70%";
      MemoryMax = "85%";
      OOMPolicy = "continue";

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
      # With NoNewPrivileges off, take setuid escalation away directly: an
      # empty bounding set means setuid and file-capability binaries gain
      # nothing on execve, and /run/wrappers (sudo, su, newuidmap, ...) is
      # hidden. The agent sandbox is unaffected: it writes its own uid map
      # rather than calling newuidmap, and a new user namespace starts with a
      # full bounding set (verified with the sandbox's unshare/bind/remount-ro
      # sequence under these two settings).
      CapabilityBoundingSet = "";
      InaccessiblePaths = [ "-/run/wrappers" ];
      # Hide all operator homes, then selectively expose the legacy Kiro tree
      # at its original path through a read-only bind. ACLs from the prerequisite
      # service provide file-level read permission without granting writes.
      ProtectHome = "tmpfs";
      # '-': a box without the legacy tree must still start the gateway.
      BindReadOnlyPaths = [ "-/home/orre/.kiro" ];
      # Mount propagation: MountFlags is left unset. KiroCrew's strict sandbox
      # builds each agent's "private memory view" with a NON-recursive bind of
      # every view root (sandbox.py `_mount_or_die(_root, _lower, MS_BIND,
      # "pinning private memory view source")`); the first root is the vault,
      # which carries the ReadOnlyPaths submounts. That bind once failed with
      # `AcpRuntimeDead: sandbox: BLOCKED -- pinning private memory view source
      # failed: errno 22`, and MountFlags=shared was added as the fix. It was
      # not the fix: with namespacing options on, systemd applies slave and
      # then shared propagation whether MountFlags is unset or "shared"
      # (systemd.exec(5)), and both render an identical mount table. If the
      # EINVAL returns, look elsewhere; do not set slave or private here.
      RestrictNamespaces = false; # KiroCrew strict sandbox needs namespaces
      MemoryDenyWriteExecute = false; # Node.js JIT needs W+X

      # Repositories and the vault are both writable agent workspaces now. The
      # vault is a git-crypt checkout owned by kirocrew (see
      # kirocrew-vault-git.nix); the agent edits notes in place and the
      # vault-sync service commits, reconciles, and pushes them.
      ReadWritePaths = [
        kirocrewHome
        codeCheckout
        vaultCheckout
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

      # No EnvironmentFile: MCP credentials are loaded by their launchers
      # (see kirocrew-mcp-servers.nix), not held by the gateway.

      Environment = [
        "KIROCREW_HOME=${kirocrewHome}/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "HOME=${kirocrewHome}"
        # PrivateTmp gives the unit its own empty /tmp, so the host's
        # /tmp/kirocrew is not visible here; use the private /tmp directly.
        "TMPDIR=/tmp"
        "PATH=${kirocrewHome}/.npm-global/bin:${kirocrewHome}/bin:${kirocrewHome}/.local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
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

}
