# 09: Push and open MR

**What to build:** End of `implement-ticket`: push a branch named from the ticket ID and open the MR with the existing token, with the ticket ID in the title so Linear links it (see `readpeak-linear-gitlab-linking`). Description lists the todo.md tasks and the test commands run. See `../spec.md`.

**Blocked by:** 08

**Status:** in-progress (skill step written, not run against GitLab)

- [x] Never pushes to `main` (skill pushes only `<branch>`; `main` protected; token cannot merge)
- [ ] MR appears on the Linear ticket

## Comments

**2026-10-21:** step 6 "Push and open the MR" added to
`nixos/claude-remote-skills/implement-ticket/SKILL.md`.

- Branch = the ticket's Linear `gitBranchName` from analysis.md (fallback
  `<ticket-lowercase>-<slug>`), per `readpeak-linear-gitlab-linking`. Added a
  checkbox to 06 so analysis.md records it.
- MR via the curl command already in `/etc/claude-remote/CLAUDE.md` (single
  source); title ends `(<TICKET>)`, description starts `Fixes <TICKET>`,
  lists tasks with hashes, tests run, blocked and out-of-scope items.
- MR URL goes under `## MRs` in todo.md for the review loop (issue 11).
- Check: `ec2-claude-remote-uid` asserts the step, `gitBranchName`,
  `Fixes <TICKET>` and `## MRs` (failed before, passes after).

Not verified: a real push and MR create on the box. Also unknown: whether
the MR-create response carries `web_url` with this token (it cannot read the
API otherwise). If it does not, build the URL from the returned `iid`.
