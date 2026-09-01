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

      # Allow writes only to kirocrew's own state and the workspace area.
      ReadWritePaths = [
        kirocrewHome
        "/home/orre"
        "/tmp"
      ];

      # Read-only access to the vault checkout (via vault-readers group).
      ReadOnlyPaths = [
        vaultCheckout
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

  # ── Vault checkout directory ───────────────────────────────────────────────
  # Owned by root:vault-readers, readable by kirocrew and pasta.
  # Write access is controlled by the Git-backed workflow (Phase 7 module).
  system.activationScripts.vault-checkout = lib.stringAfter [ "users" ] ''
    mkdir -p ${vaultCheckout}
    chown root:vault-readers ${vaultCheckout}
    chmod 2750 ${vaultCheckout}
  '';

  # ── Ensure kirocrew tmp directory ──────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /tmp/kirocrew 0700 kirocrew kirocrew -"
  ];
}
