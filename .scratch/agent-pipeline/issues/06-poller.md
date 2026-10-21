# 06: Poller (systemd timer)

**What to build:** Plain code (~100 lines) on a systemd timer. Queries the "Agent Work" project, checks blockers, sets In Progress before spawning so no ticket runs twice, caps concurrent runs, logs cost per run, and comments the MR link on the issue. Holds the Linear key; the implementer does not. See `../spec.md`.

**Blocked by:** 04

**Status:** needs-triage

- [ ] A ticket with an open blocker is never started
- [ ] Two poller ticks in a row start a ticket once
- [ ] Concurrency cap is respected
- [ ] Cost per run is logged
- [ ] States move In Progress → In Review → Done
