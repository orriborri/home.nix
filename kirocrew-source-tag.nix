# Pinned KiroCrew source release — single source of truth for every host.
#
# The source builder (kirocrew-source-build.nix) clones the public KiroCrew
# repository and builds a stable tag. Left unpinned it follows whatever tag
# upstream publishes next, so a new upstream release would deploy itself to the
# gateway on the daily timer with no review. Pinning here makes upgrades
# deliberate: bump this file, rebuild, and the atomic `current` symlink flips
# to the new release (with the previous one still on disk for rollback).
#
# Consumed by:
#   - flake.nix            → kirocrew.sourceTag for the workstation + headless
#                            Home Manager outputs
#   - nixos/kirocrew-services.nix → pinnedSourceTag for the headless system
#                            service's ExecStartPre builder
#
# Must be an immutable "vX.Y.Z" tag that exists upstream (the builder fails
# fast if it does not). Verify with:
#   git ls-remote --tags https://github.com/kirodotdev/KiroCrew.git
"v0.6.0"
