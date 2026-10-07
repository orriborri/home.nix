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
#   - nixos/kirocrew-gateway.nix → pinnedSourceTag for the headless system
#                            service's ExecStartPre builder
#
# Must be a tag that exists upstream (the builder fails fast if it does not).
# Tags are mutable, so the commit it must resolve to is pinned in
# ./kirocrew-source-revs.nix; bump both files together. Verify with:
#   git ls-remote https://github.com/kirodotdev/KiroCrew.git 'refs/tags/<tag>^{}'
#
# Pinned to v0.7.2, the newest stable release (moved off the
# v0.7.0-insider.6 pre-release, originally picked for the Claude Code and
# Codex harness selector). insider.6 had a higher memory footprint; on the
# earlier 15G host (no swap) it peaked ~13.5G and exited 1 under concurrent
# member load. Addressed by resizing the EC2 host to 30G with zram swap
# (nixos/kirocrew-ec2.nix) and capping the gateway's memory with
# MemoryHigh/MemoryMax (nixos/kirocrew-gateway.nix).
"v0.7.2"
