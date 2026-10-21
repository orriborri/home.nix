# 01: EC2 workspace: repos, worktrees, skills

**What to build:** A script on the EC2 box that clones every GitLab group repo into `/work/repos`, creates one git worktree per ticket, and installs the Claude Code plugins and skills from a versioned repo. Then run `/setup-matt-pocock-skills` in mononode with Linear as the tracker. See `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-human

- [ ] All group repos cloned under `/work/repos`; re-running the script fetches instead of re-cloning
- [ ] A command creates and removes a per-ticket worktree
- [ ] Plugins and skills match the laptop set, pinned to a version
- [ ] mononode has the Matt Pocock skill setup with Linear as tracker
