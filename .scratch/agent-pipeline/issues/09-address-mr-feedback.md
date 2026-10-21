# 09: `address-mr-feedback` skill

**What to build:** A skill (~30 lines, Haiku) that reads unresolved MR discussions, fixes them, and replies on each thread. The poller tracks the last seen note ID per MR and spawns a run when new unresolved threads appear (human, CodeRabbit, or the review run). See `../spec.md`.

**Blocked by:** 06

**Status:** needs-triage

- [ ] Each addressed thread gets a reply naming the commit
- [ ] No run starts without new unresolved threads
- [ ] After 3 rounds it stops and pings the human
