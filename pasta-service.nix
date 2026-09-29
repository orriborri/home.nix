{
  config,
  lib,
  pkgs,
  pkgs-stable,
  # Only the workstation homeConfiguration (flake.nix mkHome) passes this;
  # headless/EC2 profiles fall back to pkgs-stable, which is never forced
  # since isPastaHost is false there.
  pkgs-rust ? pkgs-stable,
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
      # it's always codegen'd on x86_64. nixos-24.11's cargo (1.82) avoids
      # that bug but is too old for edition2024 (datafusion et al. need it,
      # stable since rustc 1.85). pkgs-rust is a dedicated nixpkgs pin
      # (flake input nixpkgs-rust, rustc 1.91.1) verified to build both.
      pkgs-rust.cargo
      pkgs-rust.rustc
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
    home.packages = with pkgs; [
      protobuf
      pkg-config
      openssl
    ] ++ [ vaultWrapper ];

    # kb-cli builds to target/release/kb; expose it on interactive PATH too
    # (the systemd service only sets PATH for pasta-backend's own exec).
    home.sessionPath = [
      "${pastaRoot}/target/release"
    ];

    systemd.user.services.pasta = {
      Unit = {
        Description = "Pasta daemon (Obsidian vault indexer)";
        After = [ "network-online.target" "sops-nix.service" ];
        Wants = [ "network-online.target" "sops-nix.service" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pastaBuildAndRun}/bin/pasta-start";
        # Keep the daemon startable when this host has no SOPS age key; the
        # Slack helper then falls back to its existing token file.
        EnvironmentFile = "-${config.sops.templates."pasta-fetchers.env".path}";
        # First build from source can take a while on Graviton.
        TimeoutStartSec = "30min";
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = pastaRoot;
        Environment = [
          "PATH=%h/.local/bin:/etc/profiles/per-user/orre/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
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
  };
}
