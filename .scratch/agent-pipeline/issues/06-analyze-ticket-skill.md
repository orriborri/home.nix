# 06: `analyze-ticket` skill

**What to build:** A skill that takes a ticket ID, reads the ticket, and finds everything the change could affect across all repos: code-review-graph (`cross_repo_search`, `get_impact_radius`, callers/imports) plus `rg` for runtime links the graph misses (queue topics, S3 paths, env vars, API contracts). Writes `workspace/<TICKET>/analysis.md` and stops. See `../spec.md`.

**Blocked by:** 02, 03, 05

**Status:** in-progress (skill written; trialled on a fake ticket against real repos)

- [x] analysis.md lists affected repos, files and callers with `file:line`
- [x] analysis.md has a dependency graph (mermaid) and risks/open questions
- [x] Each claim cites the graph query or `rg` command behind it
- [x] analysis.md records the ticket's Linear `gitBranchName` (implement-ticket names the branch from it, see 09)
- [ ] Tried on one real ticket; result recorded in `## Comments`

## Comments

**2026-10-21: skill at `nixos/claude-remote-skills/analyze-ticket/SKILL.md`.**

- Input is `~/workspace/<TICKET>/ticket.md`; the skill never calls Linear.
  Who writes ticket.md is decided by issue 03 (key on the box) or 07
  (launcher fetches it on the laptop).
- Steps: terms → graph (`cross_repo_search_tool`, callers/importers/tests,
  `get_impact_radius_tool`) → `rg` literal search for string coupling →
  analysis.md (Acceptance criteria, Affected with evidence IDs, mermaid,
  Risks, Open questions, Evidence) → stop.
- Box support added: ripgrep in the unit's PATH and
  `RIPGREP_CONFIG_PATH=/etc/claude-remote/ripgreprc` (`--hidden`,
  `--glob=!.git`). Reason: in the trial every `rg -g '!.git'` call was
  refused; a `!` on the command line asks for permission per search.

Checks (failed before, pass after): `ec2-claude-remote-uid` (skill ships,
rg command has no `!` glob), `ec2-claude-remote-unit` (RIPGREP_CONFIG_PATH),
`claude-remote-sandbox` VM test (rg inside the unit finds a literal in
`.gitlab-ci.yml`, not in `.git`).

Trial (laptop, Sonnet, crg via `--mcp-config`, real repos under
`~/code/readpeak`, fake ticket "rename CLICK_QUEUE_URL to CLICKS_QUEUE_URL"):
31 turns, $0.35, 61 s. Result: 6 Affected rows across mononode,
cloudformation, nativeflow and cdk/docs/legacy, each citing evidence;
13 Evidence rows. The graph found 0 hits for the env var itself (E1); every
env-var hit came from the literal search. That confirms step 3 is needed.
Top risk found: `mononode/readpeak-common/src/Configuration.ts:129` falls
back to a hard-coded staging queue URL when the var is unset, so a
read-new-only rollout would silently send prod clicks to staging.

Remaining checkbox: try on a real Linear ticket on the box.
