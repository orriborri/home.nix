{
  config,
  lib,
  pkgs,
  pkgs-stable,
  ...
}:

# Home-manager module: pasta daemon as a systemd user service.
# Pasta is a Rust project that builds from source at ~/pasta. The repo is
# cloned by the EC2 launcher's repo-sync step; this module only owns the
# build and autostart.
let
  cfg = config.kirocrew;
  # On headless/EC2 hosts, Pasta runs as a hardened system service under the
  # dedicated pasta user (nixos/kirocrew-services.nix). This Home Manager
  # user-level service is available for workstation profiles if needed.
  isPastaHost = cfg.enable && cfg.role == "workstation";
  pastaRoot = "${config.home.homeDirectory}/code/pasta";
  pastaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];
  pastaBuildAndRun = pkgs.writeShellApplication {
    name = "pasta-start";
    runtimeInputs = [
      pkgs.coreutils
      # nixos-unstable's rustc (currently 1.98.1) mis-lowers the avx512vnni
      # vpdpwssd intrinsic (stdarch/LLVM signature mismatch) when
      # lance-linalg compiles its SIMD kernels, regardless of RUSTFLAGS --
      # the offending fn is #[target_feature(enable = "avx512vnni")], so
      # it's always codegen'd on x86_64. nixos-26.05's rustc 1.95.0 builds
      # pasta-backend and kb-cli including lance-linalg (verified 2026-10-08),
      # so the stable channel replaces the old dedicated rustc pin.
      pkgs-stable.cargo
      pkgs-stable.rustc
      pkgs.gcc
      pkgs.pkg-config
      pkgs.openssl
      pkgs.protobuf
      pkgs.git
    ];
    text = ''
      cd ${lib.escapeShellArg pastaRoot}

      echo "Building pasta-backend..."
      cargo build --release -p pasta-backend -p kb-cli

      # LD_LIBRARY_PATH is scoped to the built binary's exec only: setting it
      # for the whole unit (build included) puts unstable's glibc ahead of
      # the stable-channel cargo/rustc's own rpath, so cargo fails to start
      # with "GLIBC_ABI_DT_X86_64_PLT not found".
      export LD_LIBRARY_PATH="${pastaLibraryPath}"
      export PATH="${lib.escapeShellArg pastaRoot}/target/release:$PATH"
      exec ${lib.escapeShellArg pastaRoot}/target/release/pasta-backend
    '';
  };
  vaultWrapper = pkgs.writeShellScriptBin "vault" ''
    exec ${pkgs.python3}/bin/python3 ${lib.escapeShellArg pastaRoot}/llm-wiki/vault.py "$@"
  '';
in
{
  config = lib.mkIf isPastaHost {
    # Build dependencies available system-wide for rebuilds.
    home.packages =
      with pkgs;
      [
        protobuf
        pkg-config
        openssl
      ]
      ++ [ vaultWrapper ];

    # kb-cli builds to target/release/kb; expose it on interactive PATH too
    # (the systemd service only sets PATH for pasta-backend's own exec).
    home.sessionPath = [
      "${pastaRoot}/target/release"
    ];

    systemd.user.services.pasta = {
      Unit = {
        Description = "Pasta daemon (Obsidian vault indexer)";
        After = [
          "network-online.target"
          "sops-nix.service"
        ];
        Wants = [
          "network-online.target"
          "sops-nix.service"
        ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pastaBuildAndRun}/bin/pasta-start";
        # Keep the daemon startable when this host has no SOPS age key; the
        # Slack helper then falls back to its existing token file.
        # sops-nix expands %r itself, systemd does not (it warns and reads
        # nothing); %t is the runtime dir sops-nix writes to.
        EnvironmentFile = "-${
          lib.replaceStrings [ "%r" ] [ "%t" ] config.sops.templates."pasta-fetchers.env".path
        }";
        # First build from source can take a while on Graviton.
        TimeoutStartSec = "30min";
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = pastaRoot;
        Environment = [
          "PATH=%h/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
          "PROTOC=${pkgs.protobuf}/bin/protoc"
          "PROTOC_INCLUDE=${pkgs.protobuf}/include"
          "OPENSSL_DIR=${pkgs.openssl.dev}"
          "OPENSSL_LIB_DIR=${pkgs.openssl.out}/lib"
          "OPENSSL_INCLUDE_DIR=${pkgs.openssl.dev}/include"
          "PKG_CONFIG_PATH=${pkgs.openssl.dev}/lib/pkgconfig"
          # This host's CPU lacks avx512vnni anyway; harmless to disable even
          # though the real lance-linalg build fix is the stable-channel
          # rustc pinned above (see runtimeInputs comment).
          "RUSTFLAGS=-Ctarget-feature=-avx512f,-avx512bw,-avx512cd,-avx512dq,-avx512vl,-avx512vnni"
        ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # pasta-start rebuilds in-tree on every daemon start, and dependency bumps
    # (lance, arrow, datafusion) leave the old artifacts behind: target/ grew
    # to 28G and filled the disk on 2026-10-07. cargo has no target-dir GC, so
    # sweep artifacts untouched for 7 days once a week. --time only looks at
    # mtimes, so the daemon's current release build is never removed.
    systemd.user = {
      services.cargo-sweep = {
        Unit = {
          Description = "Sweep stale cargo build artifacts under ~/code";
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.cargo-sweep}/bin/cargo-sweep sweep --time 7 --recursive ${config.home.homeDirectory}/code";
        };
      };

      timers.cargo-sweep = {
        Unit = {
          Description = "Weekly cargo sweep";
        };
        Timer = {
          OnCalendar = "Sun 04:00";
          Persistent = true;
        };
        Install = {
          WantedBy = [ "timers.target" ];
        };
      };
    };
  };
}
