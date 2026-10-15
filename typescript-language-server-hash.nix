{ ... }:

# nixos-unstable 7fd4004d (2026-10-11) ships typescript-language-server 6.0.2
# with a wrong pnpm deps hash, so neovim (which bundles it) fails to build.
# NixOS/nixpkgs#572951 fixed the hash on master. Use that hash only while
# upstream still has the bad one; drop this module once nixos-unstable
# includes the fix.
let
  badHash = "sha256-MUSxDMlbG21KSesGdEvqa2kEpuVfLlXRUX1qV/FGsSo=";
  fixedHash = "sha256-xR/EF60lVBsITKgH7wCM2wHM46PFQevD51KfCENSUH4=";
in
{
  nixpkgs.overlays = [
    (final: prev: {
      typescript-language-server =
        if prev.typescript-language-server.pnpmDeps.outputHash != badHash then
          prev.typescript-language-server
        else
          prev.typescript-language-server.overrideAttrs (old: {
            pnpmDeps = old.pnpmDeps.overrideAttrs { outputHash = fixedHash; };
          });
    })
  ];
}
