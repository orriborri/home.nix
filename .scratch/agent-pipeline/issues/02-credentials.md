# 02: Credentials: GitLab bot user and Linear API key

**What to build:** A GitLab bot user with Developer role (`main` protected, no merge rights) and a Linear API key, both stored in Secrets Manager and loaded at boot. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-human

- [ ] Bot user can push branches and open MRs, cannot merge or push to `main`
- [ ] Linear key can read and update issues in the "Agent Work" project's team
- [ ] Linear MCP accepts the key as a bearer token (checked, not assumed)
- [ ] Both secrets load at boot; nothing is written to disk in plaintext
