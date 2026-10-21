# 10: `launch-ec2 implement <TICKET>`

**What to build:** A launcher command that opens the session with `/implement-ticket <TICKET>` in `workspace/<TICKET>/`. Refuses if `analysis.md` does not exist yet. See `../spec.md`.

**Blocked by:** 07, 08

**Status:** in-progress (code done, not run on the box)

- [x] Refuses without `analysis.md`
- [ ] Re-running resumes from the existing todo.md
- [x] Launcher tests pass

## Comments

**2026-10-21:** `launch-ec2 implement RP-123` (`TICKET_COMMANDS` shared with
analyze in `models.py`/`cli.py`; `launcher.py _open_implement`) checks
`/var/lib/claude-remote/workspace/RP-123/analysis.md`, refuses with
"run 'launch-ec2 analyze RP-123' first", else runs
`claude-remote-session RP-123 implement-ticket`. 3 new tests failed before,
pass after; 58 Python tests pass; flake check passes. Refactor: one
`_remote_exists` helper for the login and analysis probes. Docs in
`nixos/kirocrew.md`.

Resume is the skill's job ("If todo.md already exists, this is a resume");
not verified on the box.
