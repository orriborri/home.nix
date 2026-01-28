{ pkgs, lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper }:

stdenv.mkDerivation rec {
  pname = "kiro-ide";
  version = "0.8.140";

  src = builtins.fetchTarball {
    url = "https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${version}/tar/kiro-ide-${version}-stable-linux-x64.tar.gz";
  };

  nativeBuildInputs = [
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
      --add-flags "''${NIXOS_OZONE_WL:+''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations}}"

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
    license = licenses.unfreeRedistributable;  # Allows evaluation in flake check
  };
}
