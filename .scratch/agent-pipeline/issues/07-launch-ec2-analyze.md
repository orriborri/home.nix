# 07: `launch-ec2 analyze <TICKET>`

**What to build:** A launcher command that starts the box if needed and opens the interactive session from 01 with `/analyze-ticket <TICKET>`, in `workspace/<TICKET>/`. Add it to `COMMANDS`, `cli.py` help, and `nixos/kirocrew.md`. See `../spec.md`.

**Blocked by:** 01, 06

**Status:** needs-triage

- [ ] `launch-ec2 analyze RP-123` opens the session in the terminal
- [ ] The same session is visible in claude.ai/code (if 01 says it can be)
- [ ] Missing or malformed ticket ID fails before connecting
- [ ] Launcher tests pass
