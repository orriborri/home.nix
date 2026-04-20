{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  xz,
  bzip2,
}:

stdenv.mkDerivation rec {
  pname = "kiro-cli";
  version = "2.0.0";

  src = fetchurl {
    url = "https://desktop-release.q.us-east-1.amazonaws.com/${version}/kirocli-x86_64-linux.tar.gz";
    hash = "sha256-SNDsdF45BfrokL/6ZCl4u+AX5uUC90b2cyPurlPiiG8=";
  };

  sourceRoot = "kirocli";

  strictDeps = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    stdenv.cc.cc.lib
    xz
    bzip2
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/kiro-cli -t $out/bin
    install -Dm755 bin/kiro-cli-chat $out/bin/kiro-cli-chat
    install -Dm755 bin/kiro-cli-term $out/bin/kiro-cli-term
    runHook postInstall
  '';

  meta = with lib; {
    description = "Command-line interface for Kiro, an agentic IDE";
    homepage = "https://kiro.dev";
    license = licenses.unfree;
    sourceProvenance = [ sourceTypes.binaryNativeCode ];
    mainProgram = "kiro-cli";
    platforms = [ "x86_64-linux" ];
  };
}
