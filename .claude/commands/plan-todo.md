---
description: Break todo.md into atomic tasks, build a dependency graph, regroup into work packages, rewrite todo.md. No code changes, no commit.
---

Work through todo.md in this repo and turn it into an execution plan. Run start to finish without asking questions or waiting for approval. Do not change any code or config. The only files you may write are todo.md and BACKLOG.md.

Context:
- todo.md is the plan. BACKLOG.md holds the findings: each has an ID (S4, C19, …), file:line evidence and a `[ ]`/`[x]` state. Both are gitignored working files; never `git add -f` them and never commit.
- Treat both files as claims, not facts. Before planning an item, check its file:line references against the current code and record whether the item is still valid, already fixed, or changed. Use repo inspection and read-only commands only (grep, git log, nix eval, nix flake check, --dry-run builds). Never run switch, deploy, push, or anything that touches the EC2 host.

Concurrency: an implementer loop (/implement-todo) may be editing todo.md at the same time.
- Lines marked `[x]` (done), `[-]` (blocked or won't do) and `[~]` (in progress) belong to the implementer. Keep their text, position relative to each other, and section unchanged. Reshape only `[ ]` items.
- Re-read todo.md immediately before writing it, and write the whole file in one Write call. Never write from a copy you read earlier.
- Do not touch the git index or working tree (no stash, checkout, reset).

Step 1: Decompose.
Break every open `[ ]` item into atomic tasks. A task is atomic when all of these hold:
- it fits in one commit with one Conventional Commit message,
- it touches as few files as possible (name them),
- it has one concrete verification command or check (e.g. `nix flake check`, `home-manager build --flake .#orre`, `nix build .#nixosConfigurations.kirocrew-ec2.config.system.build.toplevel --dry-run`, a grep),
- it cannot be split further without leaving the repo broken between the pieces.
Give each task an ID derived from its parent (S4 → S4.1, S4.2 …). Tag each task with effort (S under 30 min, M a few hours, L a day or more) and whether it touches the EC2 host. Investigation steps are tasks too.

Step 2: Decide.
Wherever a task depends on a choice (delete vs keep, pin vs drop, which of two mechanisms), make the choice yourself. Prefer, in order: the option BACKLOG.md recommends, the smaller change, the safer default, the option that removes code. Record each decision as one line: choice + reason. Only mark a task "blocked: needs on-box access" or "blocked: needs credentials" when the repo cannot answer it; never block a task on preference.

Step 3: Dependency graph.
For every pair of tasks where order matters, add an edge A → B with a one-line reason. Use only these reason types:
- blocks: B is impossible or wrong before A,
- same-file: both edit the same lines or block, so doing A first avoids conflicts,
- verifies: A provides the check B relies on,
- decides: A is an investigation whose outcome changes B.
Don't add edges for preference only. If you find a cycle, break it by splitting a task and note how.

Step 4: Regroup.
Group tasks back into work packages. A package is a set of tasks that should land together because they share files, form a chain, or share one verification run. Rules:
- each package has a one-sentence goal and a single "done when" check,
- packages are at most about a day of work; split bigger ones,
- a package never mixes EC2-touching tasks with workstation-only tasks unless an edge forces it,
- blocked tasks go in their own package so they don't stall others.

Step 5: Rewrite todo.md with these sections, in order:
1. Health check: keep the existing table and update any row whose result changed.
2. Stale or already fixed: items you dropped, with the evidence. Also flip their `[ ]` to `[x]` in BACKLOG.md with the evidence.
3. Decisions made: one line each.
4. Package graph: Mermaid, package-level edges only.
5. Package table: package | tasks | effort | EC2? | depends on | done when.
6. Order: a linear order, plus which packages can run in parallel. The implementer works top to bottom, so put the first package to start first.
7. Packages: each package's atomic tasks as `- [ ]` checkboxes with ID, files, verification command, effort, and the BACKLOG.md ID for the long write-up. Carry `[x]`, `[-]` and `[~]` lines over verbatim inside their package.
Do not renumber or delete existing BACKLOG.md IDs.

Step 6: Validate.
- Every open item from the old todo.md appears in sections 2 or 7, and none is lost.
- Every task's dependencies sit in the same or an earlier package.
- `git status --short` shows no change from you (both files are ignored).

Finish with three lines: the number of packages, the first package to start, and the number of blocked tasks.

Style: terse, file:line references, no filler. If something cannot be verified from the repo, say so in the file instead of guessing.
