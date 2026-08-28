{
  config,
  lib,
  pkgs,
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
  pastaRoot = "${config.home.homeDirectory}/pasta";
  pastaLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];
  pastaBuildAndRun = pkgs.writeShellApplication {
    name = "pasta-start";
    runtimeInputs = with pkgs; [
      coreutils
      cargo
      rustc
      gcc
      pkg-config
      openssl
      protobuf
      git
    ];
    text = ''
      cd ${lib.escapeShellArg pastaRoot}

      # Build if binary is missing or source is newer.
      if [ ! -f target/release/pasta-backend ] || \
         [ "$(find crates -name '*.rs' -newer target/release/pasta-backend 2>/dev/null | head -1)" ]; then
        echo "Building pasta-backend..."
        cargo build --release -p pasta-backend -p kb-cli
      fi

      export PATH="${lib.escapeShellArg pastaRoot}/target/release:$PATH"
      exec ./target/release/pasta-backend
    '';
  };
in
{
  config = lib.mkIf isPastaHost {
    # Build dependencies available system-wide for rebuilds.
    home.packages = with pkgs; [
      protobuf
      pkg-config
      openssl
    ];

    systemd.user.services.pasta = {
      Unit = {
        Description = "Pasta daemon (Obsidian vault indexer)";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pastaBuildAndRun}/bin/pasta-start";
        # First build from source can take a while on Graviton.
        TimeoutStartSec = "30min";
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = pastaRoot;
        Environment = [
          "PATH=%h/.local/bin:/etc/profiles/per-user/orre/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
          "LD_LIBRARY_PATH=${pastaLibraryPath}"
          "PROTOC=${pkgs.protobuf}/bin/protoc"
          "PROTOC_INCLUDE=${pkgs.protobuf}/include"
        ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
