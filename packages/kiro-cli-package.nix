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
  version = "2.8.1";

  src = fetchurl {
    url = "https://desktop-release.q.us-east-1.amazonaws.com/latest/kirocli-x86_64-linux.tar.gz";
    hash = "sha256-6HAczZP8cCChkZ4rN3I+15vwABHm1LvSu+CKgIbNqRM=";
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
    install -Dm755 bin/q $out/bin/q
    install -Dm755 bin/qchat $out/bin/qchat
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
