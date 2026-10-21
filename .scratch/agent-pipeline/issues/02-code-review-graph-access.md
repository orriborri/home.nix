# 02: code-review-graph for `claude-remote`

**What to build:** Give `claude-remote` read-only use of the graphs that `kirocrew-code-review-graph-sync` already builds for every repo under `/var/lib/code/readpeak`, as an MCP server in its Claude config, so cross-repo search and impact radius work. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** in-progress (code done, not deployed)

- [x] `claude-remote` can query crg: loopback MCP server `code-review-graph-mcp` as `kirocrew` (approach changed: no crg binary for `claude-remote`)
- [x] Graphs stay read-only for `claude-remote`: the server exposes only query tools (`--tools`); the unit sandbox keeps `/var/lib/code` read-only
- [ ] `cross_repo_search` over all repos returns hits for a known shared symbol
- [x] `nix build .#nixosConfigurations.kirocrew-ec2.config.system.build.toplevel --dry-run` passes; `nixos/tests/claude-remote.nix` still passes

## Comments

**2026-10-21: implemented, not deployed.**

Why a server instead of giving `claude-remote` the crg binary: `GraphStore`
opens `graph.db` read/write and sets WAL even for queries
(`code_review_graph/graph.py:191`), so a query fails inside the unit's
read-only `/var/lib/code`. One server as `kirocrew` (which owns the graphs)
avoids that. The daemon already registers every graphed repo in kirocrew's
registry (`code_review_graph/daemon.py:775`), so `cross_repo_search_tool`
covers all repos with no extra registration.

Changes:
- `nixos/kirocrew-code.nix`: `code-review-graph-mcp` unit,
  `crg serve --http --host 127.0.0.1 --port 5555 --tools <24 read-only tools>`.
  Left out: build_or_update_graph, run_postprocess, embed_graph,
  generate_wiki, refactor, apply_refactor. Refactor: the three units share
  `crgWritablePaths` (EC2 drvPath unchanged by that step, `m6354xn…`).
- `nixos/kirocrew-claude-remote.nix`: `NO_PROXY=127.0.0.1,localhost`,
  `/etc/claude-remote/mcp.json`, a "Code graph" section in the uid's CLAUDE.md.
- `flake.nix`: new check `ec2-crg-mcp-readonly`; `ec2-claude-remote-uid`
  and `ec2-claude-remote-unit` extended.
- `nixos/tests/claude-remote.nix`: loopback stand-in on 5555; the unit
  reaches it directly, and without NO_PROXY the proxy refuses it (403).

Verified on the laptop: the 3 checks failed before the change and pass
after; `claude-remote-sandbox` VM test passes; `nix flake check --no-build`
passes; EC2 toplevel `--dry-run` passes.

Not verified (needs a deploy):
- `crg serve --http` 2.3.8 serves at `/mcp` and starts with `--tools`.
- "`cross_repo_search` returns hits for a known shared symbol": check after deploy.
- Nothing loads `mcp.json` yet; `launch-ec2 analyze` (07) passes
  `--mcp-config /etc/claude-remote/mcp.json`.

Review findings (accepted, not fixed):
- Port 5555 is open to every local uid on the box, not just `claude-remote`.
  The tools only read code that `code-writers` can already read.
