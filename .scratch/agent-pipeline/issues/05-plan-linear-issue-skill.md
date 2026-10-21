# 05: `/plan-linear-issue` skill

**What to build:** A planner skill: cross-repo `rg` research over `/work/repos` → `/grill-with-docs` → `/to-spec` → `/to-tickets`. Tickets use a template that enforces the implementer contract. See `../spec.md`.

**Blocked by:** 04

**Status:** needs-triage

- [ ] Ticket template has acceptance criteria, repo + test seam, blocked-by, and a size check
- [ ] Prompt lists runtime dependency hints (queue topics, S3 paths) to search for
- [ ] Posts the plan to the Linear issue and Slack, sets `plan-review`
