# Ticket agent on EC2: analyze → implement → MR → review loop

Status: needs-triage

## Goal

Two `launch-ec2` commands drive a Linear ticket from analysis to a reviewed
MR. Each opens an interactive Claude session on the EC2 box as the
`claude-remote` uid. The session is visible in the terminal and in the
Claude workspace (claude.ai/code, "kirocrew"). Nothing runs unattended in
the background.

```
./nixos/launch-ec2 analyze RP-123     # impact analysis + todo
./nixos/launch-ec2 implement RP-123   # TDD loop → MR → review comments
```

## Stage 1: analyze

1. Read the Linear ticket.
2. Find everything the change could affect across **all** repos with
   code-review-graph (`cross_repo_search`, `get_impact_radius`,
   `query_graph` callers/imports) over `/var/lib/code/readpeak/*`.
3. Add `rg` for what the graph misses: queue topics, S3 paths, env
   vars, GraphQL/REST contracts.
4. Write `analysis.md`: affected repos, files, callers, dependency graph,
   risks, open questions.
5. Stop. The human reads it before running `implement`.

## Stage 2: implement

Per-ticket internal tracker: `workspace/<TICKET>/todo.md`.

1. **Break down** the ticket into the smallest tasks possible
   (one commit, one verification each).
2. **Build a DAG** of the tasks and **group** them into packages.
3. **Sort** unblocked tasks from simplest to most complex. Pick the
   simplest.
4. **TDD loop** for that task:
   - Red: write a failing test, run it, see it fail.
   - Green: the smallest code that passes.
   - **Refactor: required, never skipped.** Record in todo.md what was
     refactored, or why nothing needed it. Tests stay green.
5. **Review** the change; append every finding to todo.md as a new task.
6. Re-sort (step 3) and repeat until todo.md has no open tasks.
7. Push a branch named after the ticket and open the MR for human review.

## Stage 3: review comments

After the push, the same session polls the MR (`/loop`). On each new
unresolved discussion from a human or a bot reviewer: fix it via the same
TDD loop, or answer it, then reply on the thread. It never merges.

## What already exists on the box

- Repos mirrored to `/var/lib/code/readpeak/<repo>`, readable by
  `claude-remote` through `code-writers` (`nixos/kirocrew-claude-remote.nix`).
- code-review-graph graphs built for each repo by
  `kirocrew-code-review-graph-sync` (`nixos/kirocrew-code.nix:297`), owned
  by the `kirocrew` uid.
- `claude-remote` can push and create MRs with a token
  (`claude-remote-gitlab-token`) through the egress proxy.

## Gaps (the issues below)

- `claude-remote` cannot use the graphs or the crg binary.
- No Linear access: `api.linear.app` is not in the egress allowlist
  (`nixos/kirocrew-claude-egress.nix:9`) and there is no key.
- The GitLab token cannot read MR discussions or post notes.
- `claude-remote` has no skills; only `/etc/claude-remote/CLAUDE.md`.
- Not verified: how `launch-ec2` starts an interactive session that also
  shows up in the Claude workspace.

## Open decisions

- Linear: read-only API key for `claude-remote`, or `launch-ec2` fetches
  the ticket on the laptop and passes the text in. Recommend the key
  (the session can re-read comments).
- Poll interval for review comments, and when the loop stops.

## Later

- Retro after merge: learnings to docs, ADR and skills through an MR.

## Issues

| # | Issue | Size | Blocked by |
|---|---|---|---|
| 01 | Verify: interactive session over launch-ec2, visible in Claude workspace | S | — |
| 02 | code-review-graph for `claude-remote` | M | — |
| 03 | Linear read access for `claude-remote` | S | — |
| 04 | GitLab token: read MRs, post notes | S | — |
| 05 | Ship skills to `claude-remote` | M | — |
| 06 | `analyze-ticket` skill | M | 02, 03, 05 |
| 07 | `launch-ec2 analyze <TICKET>` | M | 01, 06 |
| 08 | `implement-ticket` skill (todo, DAG, simplest-first TDD) | L | 05 |
| 09 | Push and open MR | S | 08 |
| 10 | `launch-ec2 implement <TICKET>` | S | 07, 08 |
| 11 | Review-comment loop | M | 04, 09 |

Size: S under 30 min, M a few hours, L a day.
