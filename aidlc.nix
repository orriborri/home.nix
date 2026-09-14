{
  pkgs,
  lib,
  config,
  ...
}:

# AI-DLC workflow engine (awslabs/aidlc-workflows).
#
# aidlc must own a writable tree under $XDG_DATA_HOME/aidlc: it verifies that
# tree against a mode-sensitive integrity manifest, which a read-only Nix store
# copy cannot satisfy. See packages/aidlc.nix for the measurements behind that.
#
# So the assets are pinned in the store and upstream's own installer step lays
# out the tree here at activation. The version is declared in git, activation
# runs fully offline, and aidlc keeps working the way it expects -- `aidlc
# doctor` reports a healthy install and `aidlc update` stays functional.
let
  aidlcDist = pkgs.callPackage ./packages/aidlc.nix { };

  # Upstream publishes prebuilt binaries only for these systems; notably there
  # is no aarch64-linux asset, so the Graviton/headless profile must skip this
  # entirely. Nix's laziness means aidlcDist is never forced when unsupported.
  supported = builtins.elem pkgs.stdenv.hostPlatform.system [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  inherit (aidlcDist.passthru) version binaryAsset;

  # Paths aidlc derives itself: the install root is always
  # $XDG_DATA_HOME/aidlc, and the launcher goes in the user bin dir that
  # home.sessionPath already exposes.
  installRoot = "${config.home.homeDirectory}/.local/share/aidlc";
  binDir = "${config.home.homeDirectory}/.local/bin";
in
{
  # Idempotent: install-apply only runs when the recorded active version differs
  # from the pinned one, so a no-op switch costs a single file read. A failure is
  # reported but never aborts activation -- the existing install stays usable.
  home.activation = lib.optionalAttrs supported {
    aidlc = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      aidlcCurrent=""
      if [ -r "${installRoot}/active-version" ]; then
        aidlcCurrent=$(cat "${installRoot}/active-version" 2>/dev/null || true)
      fi

      if [ "$aidlcCurrent" != "${version}" ]; then
        $DRY_RUN_CMD mkdir -p "${installRoot}" "${binDir}"
        AIDLC_INSTALL_ROOT="${installRoot}" AIDLC_BIN_DIR="${binDir}" \
          $DRY_RUN_CMD ${aidlcDist}/${binaryAsset} system lifecycle install-apply \
          --from ${aidlcDist} --version ${version} --quiet \
          || echo "aidlc: install-apply failed; existing install left untouched" >&2
      fi
    '';
  };
}
