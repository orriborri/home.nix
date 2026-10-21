# 10: Retro run

**What to build:** When every sub-issue of a parent is Done, a Sonnet run does `/retro`, opens an MR with the ADR, docs and skill changes, and runs `rp-base:capture-answer`. See `../spec.md`.

**Blocked by:** 09

**Status:** needs-triage

- [ ] Triggers once per parent, only when all sub-issues are Done
- [ ] Learnings land as an MR, never a direct push
