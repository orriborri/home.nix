# 10: `launch-ec2 implement <TICKET>`

**What to build:** A launcher command that opens the session with `/implement-ticket <TICKET>` in `workspace/<TICKET>/`. Refuses if `analysis.md` does not exist yet. See `../spec.md`.

**Blocked by:** 07, 08

**Status:** needs-triage

- [ ] Refuses without `analysis.md`
- [ ] Re-running resumes from the existing todo.md
- [ ] Launcher tests pass
