# 01: Verify: interactive session over launch-ec2, visible in Claude workspace

**What to build:** Find out how `launch-ec2` can open an interactive `claude` session as `claude-remote` (over SSM, in the terminal) that starts from an initial prompt and also appears in claude.ai/code. Today `claude-remote.service` runs `claude remote-control --spawn same-dir`, which waits for sessions started from the web. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** needs-triage

- [x] Documented: the exact command that starts a session with an initial prompt (e.g. `claude "/analyze-ticket RP-123"`)
- [ ] Documented: whether that session shows up in claude.ai/code, and what flag or setting it needs
- [x] Documented: what happens to the session when the SSM connection drops (zellij/tmux needed?)
- [x] Findings in `## Comments` below

## Comments

**2026-10-21 (laptop, Claude Code 2.1.306, not yet checked on the box):**

- Command found in `claude --help`: `claude --remote-control "<name>" "<prompt>"`
  starts an interactive session with an initial prompt and Remote Control
  enabled, so it should show up in claude.ai/code under `<name>`.
  Candidate: `claude --remote-control "RP-123 analyze" "/analyze-ticket RP-123"`.
- Still to check on the box: the EC2 runs `pkgs.claude-code` from nixpkgs,
  which may be older than 2.1.306 and not have the flag. Run
  `claude --version` and `claude --help | grep remote-control` there.
- Sandbox gap: `launch-ec2 claude` runs the login as
  `sudo -u claude-remote -H env HTTPS_PROXY=…` (`nixos/kirocrew_ec2/launcher.py:538`).
  That only sets the proxy variables. It does not apply the unit's
  `IPAddressDeny=any`, `ProtectSystem=strict`, `UnsetEnvironment` or
  `GIT_CONFIG_GLOBAL`, so a session started this way could ignore the proxy.
  Start it as a transient unit with the same properties instead, e.g.
  `systemd-run --uid=claude-remote --pty --same-dir -p IPAddressDeny=any -p IPAddressAllow=localhost …`,
  or move the hardening into a wrapper that both the service and the
  launcher use.
- SSM drop: an interactive process dies with the SSM session. Run it inside
  zellij (`nixos/kirocrew-zellij`) so `launch-ec2 analyze` can re-attach.
  With Remote Control on, the session can also be continued from
  claude.ai/code while the process is alive.

**2026-10-21 (on the box, as `orre`):** `claude --version` → `2.1.296`;
`claude --help` lists `--remote-control [name]`. The flag exists on the box.
Not yet checked: that this is the same binary `claude-remote` runs
(`/run/current-system/sw/bin/claude` vs. `orre`'s PATH), and that a
session started with the flag appears in claude.ai/code. Both get checked
by the first real run of 07.
