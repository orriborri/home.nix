# 03: Linear read access for `claude-remote`

**What to build:** Let the session read a Linear ticket and its comments. Add `api.linear.app` (and the MCP host if used) to the egress allowlist and give `claude-remote` a read-only Linear API key through sops, the same way as `claude-remote-gitlab-token`. See `../spec.md` (open decision: key vs. laptop fetch).

**Blocked by:** None (can start immediately)

**Status:** ready-for-human (needs the Linear key)

- [ ] Key is read-only
- [ ] Only the needed Linear host is added to `nixos/kirocrew-claude-egress.nix`
- [ ] A session can fetch a ticket by ID
