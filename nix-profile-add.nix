{ lib, options, ... }:

# Home Manager's installPackages step still runs `nix profile install`, which
# Nix 2.34 reports on every switch as "'install' is a deprecated alias for
# 'add'". Reuse Home Manager's own step with the new name so it keeps tracking
# upstream. Drop this module once upstream uses `nix profile add`.
let
  upstream =
    (lib.findFirst
      (d: lib.hasSuffix "/modules/home-environment.nix" d.file && d.value ? installPackages)
      (throw "home-environment.nix no longer defines home.activation.installPackages")
      options.home.activation.definitionsWithLocations
    ).value.installPackages;
in
{
  home.activation.installPackages = lib.mkForce (
    upstream
    // {
      data = lib.replaceStrings [ "profile install" ] [ "profile add" ] upstream.data;
    }
  );
}
