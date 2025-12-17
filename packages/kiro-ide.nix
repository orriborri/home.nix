{ stdenv, fetchurl, autoPatchelfHook, makeWrapper, lib }:

stdenv.mkDerivation rec {
  pname = "kiro-ide";
  version = "0.6.32";

  src = fetchurl {
    url = "https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${version}/tar/kiro-ide-${version}-stable-linux-x64.tar.gz";
    sha256 = "sha256-XZFLKGNxv0AGSZtRhp1sJH3MClEAXSSWN6HYYA7qBQQ=";
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/lib/kiro-ide
    cp -r . $out/lib/kiro-ide
    makeWrapper $out/lib/kiro-ide/kiro $out/bin/kiro-ide
  '';

  meta = {
    description = "Kiro IDE - AI-powered development environment";
    platforms = lib.platforms.linux;
  };
}
