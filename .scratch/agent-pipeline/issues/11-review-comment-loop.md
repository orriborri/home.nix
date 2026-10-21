# 11: Review-comment loop

**What to build:** An `address-mr-feedback` skill run by `/loop` in the same session after the MR opens. On each new unresolved discussion (human or bot): fix it through the TDD loop, or answer it, then reply on the thread. Tracks the last seen note ID. See `../spec.md`, stage 3.

**Blocked by:** 04, 09

**Status:** needs-triage

- [ ] A comment asking for a change gets a commit and a reply naming it
- [ ] A question gets an answer, no commit
- [ ] Threads already handled are not handled twice
- [ ] Stops when the MR is merged or closed; never merges
