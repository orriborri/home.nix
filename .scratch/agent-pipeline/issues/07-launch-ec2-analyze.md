# 07: `launch-ec2 analyze <TICKET>`

**What to build:** A launcher command that starts the box if needed and opens the interactive session from 01 with `/analyze-ticket <TICKET>`, in `workspace/<TICKET>/`. Add it to `COMMANDS`, `cli.py` help, and `nixos/kirocrew.md`. See `../spec.md`.

**Blocked by:** 01, 06

**Status:** in-progress (code done, not run on the box)

- [ ] `launch-ec2 analyze RP-123` opens the session in the terminal
- [ ] The same session is visible in claude.ai/code (if 01 says it can be)
- [x] The session gets the unit's environment and sandbox (HTTPS_PROXY, NO_PROXY, RIPGREP_CONFIG_PATH, GIT_CONFIG_GLOBAL, IPAddressDeny, ProtectSystem); see 01 comments
- [x] Starts claude with `--mcp-config /etc/claude-remote/mcp.json`
- [x] Missing or malformed ticket ID fails before connecting
- [x] Launcher tests pass

## Comments

**2026-10-21: implemented, not run on the box.**

- `launch-ec2 analyze RP-123` (`cli.py`, `models.py`, `launcher.py
  _open_ticket_session`): refuses a missing or malformed ticket at parse
  time, refuses before `launch-ec2 claude` has logged the uid in, then runs
  `claude-remote-session RP-123 analyze-ticket` as root on a terminal.
- `kirocrew-claude-remote.nix`: one `sandbox` attrset (hardening, uid,
  WorkingDirectory, EnvironmentFile, IP filter, ReadWritePaths,
  UnsetEnvironment) plus `path` and `environment` feed both the service and
  `claude-remote-sandbox -- CMD` (`systemd-run --pty`, or `--pipe` without a
  terminal). `claude-remote-session` = sandbox + `claude "/SKILL TICKET"
  --remote-control="TICKET SKILL" --mcp-config /etc/claude-remote/mcp.json`.
- `nixos/kirocrew.md`: "Ticket sessions" bullet.

Tests:
- `test_launcher.py`: 8 new tests (parse, flow), failed before, pass after;
  all 55 tests in `nixos/tests` pass
  (`python3 -I -m unittest discover -s nixos/tests -p 'test_*.py'`).
- VM test: the probe run through `claude-remote-sandbox` returns exactly the
  unit's results (failed before: command not found).
- flake check, EC2 dry-run, nixfmt pass. Refactor: one
  `_claude_remote_logged_in` helper for both claude flows.

Not verified (box):
- `--remote-control="NAME"` form and the session showing in claude.ai/code.
- Trust prompt: the session runs in the workspace root, which
  `launch-ec2 claude` already trusted.
- The session dies with the SSM connection (no zellij yet).

Found, not changed (separate):
- `test_launcher.py` is not run by any flake check or the pre-push hook.
- `launch-ec2 claude` still runs login/prompts via `sudo -u claude-remote env
  HTTPS_PROXY=...`, outside the sandbox; it could use claude-remote-sandbox.
- `nixos/kirocrew.md` sandbox section is stale: says no push and no token,
  and `--spawn worktree`.
