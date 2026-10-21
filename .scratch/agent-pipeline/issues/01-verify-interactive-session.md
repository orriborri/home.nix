# 01: Verify: interactive session over launch-ec2, visible in Claude workspace

**What to build:** Find out how `launch-ec2` can open an interactive `claude` session as `claude-remote` (over SSM, in the terminal) that starts from an initial prompt and also appears in claude.ai/code. Today `claude-remote.service` runs `claude remote-control --spawn same-dir`, which waits for sessions started from the web. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** needs-triage

- [ ] Documented: the exact command that starts a session with an initial prompt (e.g. `claude "/analyze-ticket RP-123"`)
- [ ] Documented: whether that session shows up in claude.ai/code, and what flag or setting it needs
- [ ] Documented: what happens to the session when the SSM connection drops (zellij/tmux needed?)
- [ ] Findings in `## Comments` below
