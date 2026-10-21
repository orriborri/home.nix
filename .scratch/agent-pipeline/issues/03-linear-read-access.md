# 03: Linear read access for `claude-remote`

**What to build:** Let the session read a Linear ticket and its comments. Add `api.linear.app` (and the MCP host if used) to the egress allowlist and give `claude-remote` a read-only Linear API key through sops, the same way as `claude-remote-gitlab-token`. See `../spec.md` (open decision: key vs. laptop fetch).

**Blocked by:** None (can start immediately)

**Status:** in-progress (code done, not deployed)

- [x] Key scope accepted by the human 2026-10-21 (reuses sops `linear-api-key`; scope not checked)
- [x] Only the needed Linear host is added to `nixos/kirocrew-claude-egress.nix`
- [ ] A session can fetch a ticket by ID

## Comments

**2026-10-21:** decision: the box reads Linear (option 2). The human said
all needed tokens are in sops and their permissions are fine.

- `kirocrew-sops.nix`: `claude-remote-linear-api-key` (sops key
  `linear-api-key`, shared with pasta) rendered to
  `/var/lib/claude-remote/secrets/linear.env` as `LINEAR_API_KEY`.
- Unit `EnvironmentFile` now lists gitlab.env and linear.env (both optional).
- Egress: `api.linear.app` added (19 hosts).
- `/etc/claude-remote/CLAUDE.md`: Linear section with the GraphQL curl
  (`issue(id:)` with identifier, `branchName`, comments); read only.
- `analyze-ticket` fetches the ticket into `ticket.md` itself.

Checks (failed before, pass after): `ec2-claude-egress-proxy`,
`ec2-claude-remote-uid` (owned secrets), `ec2-claude-remote-unit`
(EnvironmentFile). VM test, flake check, EC2 dry-run pass.

Not verified: the GraphQL query against the live API (`issue(id:)` with an
identifier rather than a UUID). Last checkbox after deploy.
