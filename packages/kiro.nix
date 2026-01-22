{ pkgs, lib, config, ... }:

let
  # Kiro IDE - fetched from official metadata endpoint
  kiro-ide = pkgs.stdenv.mkDerivation rec {
    pname = "kiro-ide";
    version = "latest";

    src = pkgs.fetchurl {
      # Get latest from: curl -sL "https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json" | jq -r '.releases[].updateTo.url | select(endswith(".tar.gz"))' | head -1
      url = "https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/0.8.140/tar/kiro-ide-0.8.140-stable-linux-x64.tar.gz";
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
      libxkbcommon
      libxkbfile
      mesa
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
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath buildInputs}" \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations}}"

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
  home.packages = [ kiro-ide ];

  # Add Kiro CLI to PATH
  programs.zsh.profileExtra = lib.mkAfter ''
    # Kiro CLI
    export PATH="$HOME/.kiro/bin:$PATH"
  '';

  # Install Kiro CLI if not present
  home.activation.installKiro = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "$HOME/.kiro/bin/kiro" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL https://cli.kiro.dev/install | $DRY_RUN_CMD ${pkgs.bash}/bin/bash
    fi
  '';
}
