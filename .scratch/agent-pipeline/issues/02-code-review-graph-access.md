# 02: code-review-graph for `claude-remote`

**What to build:** Give `claude-remote` read-only use of the graphs that `kirocrew-code-review-graph-sync` already builds for every repo under `/var/lib/code/readpeak`, as an MCP server in its Claude config, so cross-repo search and impact radius work. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** needs-triage

- [ ] `claude-remote` can run crg (binary in its PATH, not under `/var/lib/kirocrew`)
- [ ] Graphs stay read-only for `claude-remote`; it cannot rebuild or write them
- [ ] `cross_repo_search` over all repos returns hits for a known shared symbol
- [ ] `nix build .#nixosConfigurations.kirocrew-ec2.config.system.build.toplevel --dry-run` passes; `nixos/tests/claude-remote.nix` still passes
