# 08: Review run

**What to build:** A fresh agent runs `/code-review` from the merge-base and posts findings as MR comments. Model (Sonnet or Opus) is an open decision. See `../spec.md`.

**Blocked by:** 06

**Status:** needs-triage

- [ ] Runs in a fresh process, not the implementer's session
- [ ] Each finding is one MR discussion thread
