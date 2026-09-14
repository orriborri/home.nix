{
  lib,
  stdenv,
  fetchurl,
}:

# AI-DLC (AI-Driven Development Life Cycle) release assets from awslabs.
#
# This derivation is a *distribution bundle*, not a runnable package: it pins
# every release asset by hash so activation can install offline. The companion
# module ../aidlc.nix runs upstream's `system lifecycle install-apply` against
# this directory.
#
# Why not a normal package exposing $out/bin/aidlc?
#   aidlc verifies its installed runtime tree against a baseline manifest
#   (runtime-integrity.json) that is sensitive to file modes. The Nix store
#   normalises modes to 0444/0555, so a store-owned tree fails integrity with
#   "runtime file claude/.claude/CLAUDE.md does not match the installed
#   baseline". Verified empirically: writable root => 0 doctor failures,
#   read-only store-style root => integrity failure. aidlc must therefore own a
#   writable tree under $XDG_DATA_HOME/aidlc.
#
#   Pinning the assets here still gives the properties that matter: the version
#   and hashes are declared in git, activation needs no network, and the payload
#   is verified twice (by Nix, then by aidlc's own checksums.txt + SLSA
#   provenance attestation).
#
# To upgrade: bump `version`, then refresh each hash with
#   nix-prefetch-url https://github.com/awslabs/aidlc-workflows/releases/download/v<ver>/<asset>
let
  version = "2.8.2";
  baseUrl = "https://github.com/awslabs/aidlc-workflows/releases/download/v${version}";

  # install-apply selects the binary by platform triple and requires the exact
  # upstream asset filenames, so each file is fetched under its release name.
  platformAssets = {
    x86_64-linux = {
      asset = "aidlc-linux-x64";
      sha256 = "0s1zx7z2mxg1sgms493dp4v3dvpnxjnkm72rccrcw8q3fjf75134";
    };
    aarch64-darwin = {
      asset = "aidlc-darwin-arm64";
      sha256 = "1jpn1fnl6jd30c7rjgm23nfj08zawd4k875dgir1vjgfqs8ya2gr";
    };
  };

  platform =
    platformAssets.${stdenv.hostPlatform.system}
      or (throw "aidlc: unsupported system ${stdenv.hostPlatform.system}");

  fetchAsset =
    name: sha256:
    fetchurl {
      url = "${baseUrl}/${name}";
      inherit sha256;
    };

  binary = fetchAsset platform.asset platform.sha256;

  # Platform-independent assets. install-apply refuses to proceed without the
  # provenance attestation, so it is not optional.
  runtime = fetchAsset "aidlc-runtime-${version}.tar.gz" "0wmm3vvsdsqi3i9mw9i9x0q7k9xvk5f1brj90793srv61bb0q0kd";
  versionJson = fetchAsset "version.json" "10mhicjngc08nf8rg1mk3awca2gjh695ifnzaix684zm44837piq";
  checksums = fetchAsset "checksums.txt" "0v3x3mch6cqb808179nmm8lswjq24mbh3cnf56am73hprjpch83w";
  provenance = fetchAsset "aidlc-release.intoto.jsonl" "0ax6wgpqx8g2w8pk2m2nhw21wwd6m869yw7jcmrqyyh7d0jam9g8";
in
stdenv.mkDerivation {
  pname = "aidlc-dist";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    install -m644 "${runtime}"     "$out/aidlc-runtime-${version}.tar.gz"
    install -m644 "${versionJson}" "$out/version.json"
    install -m644 "${checksums}"   "$out/checksums.txt"
    install -m644 "${provenance}"  "$out/aidlc-release.intoto.jsonl"
    install -m755 "${binary}"      "$out/${platform.asset}"

    runHook postInstall
  '';

  # The upstream binary is a Bun standalone executable; its appended payload
  # does not survive stripping, and it is installed rather than linked.
  dontStrip = true;
  dontPatchELF = true;

  passthru = {
    inherit version;
    binaryAsset = platform.asset;
  };

  meta = {
    description = "Pinned AI-DLC release assets for offline installation";
    homepage = "https://github.com/awslabs/aidlc-workflows";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames platformAssets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
