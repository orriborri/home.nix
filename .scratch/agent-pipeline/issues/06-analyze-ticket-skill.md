# 06: `analyze-ticket` skill

**What to build:** A skill that takes a ticket ID, reads the ticket, and finds everything the change could affect across all repos: code-review-graph (`cross_repo_search`, `get_impact_radius`, callers/imports) plus `rg` for runtime links the graph misses (queue topics, S3 paths, env vars, API contracts). Writes `workspace/<TICKET>/analysis.md` and stops. See `../spec.md`.

**Blocked by:** 02, 03, 05

**Status:** needs-triage

- [ ] analysis.md lists affected repos, files and callers with `file:line`
- [ ] analysis.md has a dependency graph (mermaid) and risks/open questions
- [ ] Each claim cites the graph query or `rg` command behind it
- [ ] analysis.md records the ticket's Linear `gitBranchName` (implement-ticket names the branch from it, see 09)
- [ ] Tried on one real ticket; result recorded in `## Comments`
