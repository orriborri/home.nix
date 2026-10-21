# 08: `implement-ticket` skill

**What to build:** A skill that turns `analysis.md` into `workspace/<TICKET>/todo.md` and works it to empty. Model on this repo's `/plan-todo` and `/implement-todo`. See `../spec.md`, stage 2.

**Blocked by:** 05

**Status:** needs-triage

- [ ] Breaks the ticket into the smallest tasks (one commit, one verification each)
- [ ] Builds a DAG with a reason per edge, then groups tasks into packages
- [ ] Before each loop: sorts unblocked tasks simplest → most complex and picks the simplest
- [ ] Each task runs red → green → refactor; red must be seen failing
- [ ] Refactor is never skipped: todo.md records what was refactored or why nothing needed it
- [ ] After each task: review the change, append every finding to todo.md as a task
- [ ] Stops when todo.md has no open tasks
