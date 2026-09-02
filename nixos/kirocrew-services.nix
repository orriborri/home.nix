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

  # Vault checkout location — kirocrew and pasta read via vault-readers group.
  vaultCheckout = "/var/lib/vault";

  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  pastaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];
in
{
  # ── KiroCrew gateway ───────────────────────────────────────────────────────
  systemd.services.kirocrew-gateway = {
    description = "KiroCrew Gateway";
    after = [
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "kirocrew";
      Group = "kirocrew";
      ExecStart = "${kirocrewHome}/bin/kirocrew gateway";
      Restart = "always";
      RestartSec = 5;
      TimeoutStartSec = "20min";
      WorkingDirectory = kirocrewHome;

      # ── Sandbox: strict mode ───────────────────────────────────────────
      # KiroCrew's own strict sandbox provides namespace isolation for agents.
      # systemd hardening adds defense in depth at the service level.
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p ${kirocrewHome}/.kiro/crew"
        "${kirocrewHome}/bin/kirocrew config set --local agent.sandbox strict"
      ];

      # ── systemd hardening ──────────────────────────────────────────────
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      # ProtectHome disabled: the gateway needs read access to /home/orre/
      # for workspace project directories listed in config.json.
      ProtectHome = false;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = false; # KiroCrew strict sandbox needs namespaces
      LockPersonality = true;
      MemoryDenyWriteExecute = false; # Node.js JIT needs W+X

      # KiroCrew writes the local POSIX vault; synchronization and conflict
      # handling are provided by the dedicated vault-sync service.
      ReadWritePaths = [
        kirocrewHome
        vaultCheckout
        "/home/orre"
        "/tmp"
      ];

      # Internal/index state remains read-only even though note content is
      # writable. A leading '-' makes absent paths non-fatal on first boot.
      ReadOnlyPaths = [
        "-${vaultCheckout}/.git"
        "-${vaultCheckout}/.obsidian"
        "-${vaultCheckout}/.lancedb"
        "-${vaultCheckout}/.semantic_search"
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
  # Disabled until pasta-backend is installed into /var/lib/pasta/bin/.
  # The missing binary causes switch-to-configuration to fail with exit 4.
  systemd.services.pasta-daemon = {
    enable = false;
    description = "Pasta vault indexer";
    after = [
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "pasta";
      Group = "pasta";
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
        "PASTA_VAULT_PATH=${vaultCheckout}"
        "PASTA_DATA_DIR=${pastaHome}/data"
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
  ];
}
