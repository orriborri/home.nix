{ pkgs, lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, ... }:

stdenv.mkDerivation rec {
  pname = "amazon-q-desktop";
  version = "latest";

  src = fetchurl {
    url = "https://desktop-release.q.us-east-1.amazonaws.com/latest/q-x86_64-linux.zip";
    sha256 = "sha256-W0rIKcgxktmWC2cMd55vjsAxd7ie8L7TrCcTGwqt3u8=";
  };

  nativeBuildInputs = [ pkgs.unzip autoPatchelfHook makeWrapper ];

  buildInputs = with pkgs; [
    stdenv.cc.cc.lib
    glib
    gtk3
    cairo
    pango
    atk
    gdk-pixbuf
    libdrm
    mesa
    xorg.libX11
    xorg.libxcb
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    nspr
    nss
    cups
    dbus
    expat
    at-spi2-atk
    at-spi2-core
    libxkbcommon
    alsa-lib
  ];

  unpackPhase = ''
    unzip $src
  '';

  installPhase = ''
    mkdir -p $out/bin $out/opt/amazon-q
    cp -r q/* $out/opt/amazon-q/
    chmod +x $out/opt/amazon-q/bin/q
    makeWrapper $out/opt/amazon-q/bin/q $out/bin/amazon-q-desktop
  '';

  meta = with lib; {
    description = "Amazon Q Desktop Application";
    homepage = "https://aws.amazon.com/q/";
    platforms = platforms.linux;
  };
}
