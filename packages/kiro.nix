{ pkgs, lib, config, ... }:

let
  # Kiro IDE - fetched from official metadata endpoint
  kiro-ide = pkgs.stdenv.mkDerivation rec {
    pname = "kiro-ide";
    version = "0.8.140";

    src = pkgs.fetchurl {
      # Get latest from: curl -sL "https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json" | jq -r '.releases[].updateTo.url | select(endswith(".tar.gz"))' | head -1
      url = "https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${version}/tar/kiro-ide-${version}-stable-linux-x64.tar.gz";
      sha256 = "sha256-nF4i7hSRMEvDCQ9b4rfU5X2M5x76kU6tEfxbo36vBFY=";
    };

    nativeBuildInputs = with pkgs; [
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = with pkgs; [
      stdenv.cc.cc.lib
      alsa-lib
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libGL # provides libGL.so.1
      libxkbcommon
      libxkbfile
      mesa # provides libgbm.so.1
      nspr
      nss
      pango
      xorg.libX11
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
    ];

    sourceRoot = "Kiro";

    installPhase = ''
      runHook preInstall

      mkdir -p $out/opt/kiro
      cp -r . $out/opt/kiro/

      mkdir -p $out/bin
      makeWrapper $out/opt/kiro/kiro $out/bin/kiro-ide \
        --unset LD_LIBRARY_PATH \
        --set BROWSER "/usr/bin/firefox"

      # Desktop entry
      mkdir -p $out/share/applications
      cat > $out/share/applications/kiro.desktop << EOF
      [Desktop Entry]
      Name=Kiro
      Comment=Agentic AI IDE
      Exec=$out/bin/kiro-ide %U
      Icon=$out/opt/kiro/resources/app/resources/linux/code.png
      Terminal=false
      Type=Application
      Categories=Development;IDE;
      StartupWMClass=Kiro
      EOF

      runHook postInstall
    '';

    meta = with lib; {
      description = "Kiro - Agentic AI IDE";
      homepage = "https://kiro.dev";
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  home.packages = [ 
    kiro-ide
    pkgs.xdg-utils  # Required for browser-based authentication
  ];

  # Add Kiro CLI to PATH
  programs.zsh.profileExtra = lib.mkAfter ''
    # Kiro CLI
    export PATH="$HOME/.local/bin:$HOME/.kiro/bin:$PATH"
  '';
  
  # Shell alias to default to current directory, run in background
  programs.zsh.shellAliases = {
    kiro = "kiro-ide . > /dev/null 2>&1 &";
  };

  # Install Kiro CLI if not present
  home.activation.installKiroCli = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "$HOME/.local/bin/kiro-cli" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL https://cli.kiro.dev/install | $DRY_RUN_CMD ${pkgs.bash}/bin/bash
    fi
  '';
}
