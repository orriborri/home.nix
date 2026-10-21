# 04: GitLab token: read MRs, post notes

**What to build:** Widen `claude-remote-gitlab-token` (or add a second token) so the session can list MR discussions, post replies and resolve threads. It still cannot approve or merge, and `main` stays protected. Update the token description in `nixos/kirocrew-claude-remote.nix` and `/etc/claude-remote/CLAUDE.md`. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-human (needs a new token in GitLab)

- [ ] Session can read MR discussions via the API
- [ ] Session can reply on a thread
- [ ] Merge attempt is refused
