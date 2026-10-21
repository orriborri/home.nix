# Agent pipeline on EC2: Linear ticket → MR → retro

Status: needs-triage

## Goal

A headless pipeline on the persistent EC2 box takes a Linear issue from
research to a reviewed MR, then runs a retro. Two human gates: plan approval
and merge.

## Flow

1. Label `agent` on a Linear issue → planner: cross-repo research, spec,
   sub-tickets with blocked-by links. Posts the plan to the issue and Slack,
   sets `plan-review`.
2. Human sets `plan-approved` → one fresh `claude -p` per unblocked ticket:
   `/implement` (TDD + `/code-review`), then opens the MR.
3. Fresh review run posts findings as MR comments.
4. New unresolved MR threads → `address-mr-feedback` run. Max 3 rounds, then
   ping the human.
5. Human merges → retro run opens an MR with ADR, docs and skill changes.

## Design decisions

- **Runner:** `claude -p` per stage, started by a systemd timer that polls
  Linear. No inbound ingress. Each gate ends one process; a label change
  starts the next.
- **Model auth:** Bedrock via instance role (`CLAUDE_CODE_USE_BEDROCK=1`),
  or an API key from Secrets Manager. Undecided.
- **Linear access:** only the poller (plain code) and the supervised
  planner session hold the Linear key. The implementer gets no Linear MCP
  or token. The poller injects ticket text, moves states, and comments the
  MR link.
- **GitLab:** bot user with Developer role, `main` protected, no merge
  rights. The human merge is the final gate.
- **Permissions:** allowlist in `settings.json`, not
  `--dangerously-skip-permissions`. Every run capped with `--max-turns`.
- **Repos:** all GitLab group repos cloned to `/work/repos`; one git
  worktree per ticket. Cross-repo search is local `rg`.
- **Skills:** same plugins as the laptop, installed from a versioned repo.

## Known weak spot

Cross-repo dependency search finds only what is grep-able. Runtime
dependencies (queue topics, S3 paths) need explicit hints in the planner
prompt.

## Open decisions

- How many implementer runs at once (start at 1).
- Sonnet or Opus for the review run.
- Which Slack channel gets the pings.
- Which repo the poller code lives in.
- Bedrock or Anthropic API key.

## Issues

| # | Issue | Blocked by |
|---|---|---|
| 01 | EC2 workspace: repos, worktrees, skills | — |
| 02 | Credentials: GitLab bot + Linear key | — |
| 03 | Linear project and labels | — |
| 04 | Manual tracer bullet | 01, 02, 03 |
| 05 | `/plan-linear-issue` skill | 04 |
| 06 | Poller | 04 |
| 07 | Implement prompt | 06 |
| 08 | Review run | 06 |
| 09 | `address-mr-feedback` skill | 06 |
| 10 | Retro run | 09 |
| 11 | CI failures → pipeline-doctor | 09 |
