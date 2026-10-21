# 08: `implement-ticket` skill

**What to build:** A skill that turns `analysis.md` into `workspace/<TICKET>/todo.md` and works it to empty. Model on this repo's `/plan-todo` and `/implement-todo`. See `../spec.md`, stage 2.

**Blocked by:** 05

**Status:** in-progress (skill written; trial covered 1 of 2 tasks)

- [x] Breaks the ticket into the smallest tasks (one commit, one verification each)
- [x] Builds a DAG with a reason per edge, then groups tasks into packages
- [ ] Before each loop: sorts unblocked tasks simplest → most complex and picks the simplest
- [x] Each task runs red → green → refactor; red must be seen failing
- [x] Refactor is never skipped: todo.md records what was refactored or why nothing needed it
- [ ] After each task: review the change, append every finding to todo.md as a task
- [ ] Stops when todo.md has no open tasks

## Comments

**2026-10-21: skill at `nixos/claude-remote-skills/implement-ticket/SKILL.md`,
shipped to claude-remote through `/etc/claude-remote/skills` (store copy).**

Design choices:
- User-invoked (`disable-model-invocation: true`); `launch-ec2 implement`
  types `/implement-ticket <ID>`.
- One human gate before the loop: approve Tasks, DAG and seams. This is the
  seam agreement Matt's `tdd` asks for.
- Refactor overrides Matt's `tdd` ("refactoring is not part of the loop").
  Done when the Log has `refactor:` with changes, or `refactor: none` plus
  what was inspected.
- Review per task: `code-review` against the task's start commit.
- Push and MR are left to issue 09.

Check: `ec2-claude-remote-uid` asserts the skill ships with its name,
user-invoked flag and the Red/Green/Refactor/Review/simplest sections
(failed before, passes after).

Trial (laptop, Sonnet, `claude -p`, toy repo, 2-criterion ticket):
26 turns, $0.54, 65 s. Produced Tasks/DAG (labelled same-file edge)/
Packages/Coverage/Log; red line `ImportError: cannot import name 'slugify'`;
`refactor: none` with what was inspected; `code-review` ran both sub-agents.
Stopped at `git commit`: the trial's headless allowlist refused compound
Bash commands (harness, not the skill). T2 not run, so these are not
exercised yet: sorting with more than one unblocked task, findings turned
into tasks, finishing.

Fixed after the trial: review findings were left as loose notes (tabs,
untested trim). The Review step now sends every finding to a task, Out of
scope, or a question.
