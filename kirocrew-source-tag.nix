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
# Must be an immutable tag that exists upstream (the builder fails fast if it
# does not). Verify with:
#   git ls-remote --tags https://github.com/kirodotdev/KiroCrew.git
#
# Pinned to v0.7.0-insider.4 for the crew-chat routing fixes. This pre-release
# has a higher memory footprint; on this host (15G, no swap) it peaked ~13.5G
# and exited 1 under concurrent member load. Addressed by adding swap and
# capping concurrent agent instances rather than rolling back — see
# kirocrew-services.nix and the gateway's instances.warm_set_cap.
"v0.7.0-insider.4"
