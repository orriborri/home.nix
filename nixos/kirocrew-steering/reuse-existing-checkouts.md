# Reuse the existing repo checkouts — use git worktrees, never reclone

The readpeak repositories are **already cloned on this box** and kept current
automatically. Do NOT `git clone` them again, and do NOT check an MR out into a
fresh directory (`~/Repos`, `~/code`, `/tmp/...`, `mononode-mr<N>`, etc.).
Recloning wastes disk and time and has repeatedly filled the root filesystem.

**When you check out an MR or start work on a new request, create a git
worktree off the existing checkout.** A worktree is a separate working
directory backed by the same local object store — so it costs almost nothing,
never reclones, and keeps each MR/task isolated without disturbing the shared
checkout's branch or anyone else's work.

## Where the repos already are

| Repo | Checkout | Worktree root |
|------|----------|---------------|
| cdk | `/var/lib/code/readpeak/cdk` | `/var/lib/code/wt/readpeak/cdk/` |
| cloudformation | `/var/lib/code/readpeak/cloudformation` | `/var/lib/code/wt/readpeak/cloudformation/` |
| eks-workloads | `/var/lib/code/readpeak/eks-workloads` | `/var/lib/code/wt/readpeak/eks-workloads/` |
| mononode | `/var/lib/code/readpeak/mononode` | `/var/lib/code/wt/readpeak/mononode/` |
| nativeflow | `/var/lib/code/readpeak/nativeflow` | `/var/lib/code/wt/readpeak/nativeflow/` |
| intelligence, integrator, gitlab-components, wiki, lambda, … | `/var/lib/code/readpeak/<name>` | `/var/lib/code/wt/readpeak/<name>/` |

The checkouts are refreshed every 15 minutes by the `repo-fetch` / `repo-sync`
timers (`fetch --prune` + fast-forward), and their objects come from local bare
mirrors under `/var/lib/kirocrew-repo-mirrors`. The
`/var/lib/code/wt/readpeak/<repo>/` roots are pre-created, group-writable
(`kirocrew:code-writers`), and deliberately kept OUTSIDE the checkouts so
repo-sync's fast-forward never touches your worktree. `/var/lib/code` is already
an allowed working root (`agent.subagent_cwd_allowed_roots`).

## Checking out an MR → make a worktree

```bash
REPO=/var/lib/code/readpeak/<repo>
# 1. Fetch just the MR's head into the existing checkout (reuses local objects,
#    no reclone, no branch switch on the shared checkout). If the local mirror
#    origin doesn't have the ref yet (it refreshes every 15 min), fetch that one
#    ref straight from GitLab.
git -C "$REPO" fetch origin "refs/merge-requests/<IID>/head" \
  || git -C "$REPO" fetch "https://gitlab.com/readpeak/<repo>.git" \
         "refs/merge-requests/<IID>/head"
SHA=$(git -C "$REPO" rev-parse FETCH_HEAD)

# 2. Create an isolated worktree at that SHA under the shared worktree root.
git -C "$REPO" worktree add /var/lib/code/wt/readpeak/<repo>/mr-<IID> "$SHA"

# 3. Work in it.
cd /var/lib/code/wt/readpeak/<repo>/mr-<IID>

# 4. Remove it when done (keeps the worktree root tidy).
git -C "$REPO" worktree remove /var/lib/code/wt/readpeak/<repo>/mr-<IID>
```

## Starting a NEW request / feature branch → make a worktree

```bash
REPO=/var/lib/code/readpeak/<repo>
git -C "$REPO" fetch origin
# New branch off the target (usually origin/main or origin/master):
git -C "$REPO" worktree add -b <branch-name> \
  /var/lib/code/wt/readpeak/<repo>/<branch-name> origin/main
cd /var/lib/code/wt/readpeak/<repo>/<branch-name>
# … work, commit, push from inside the worktree …
git -C "$REPO" worktree remove /var/lib/code/wt/readpeak/<repo>/<branch-name>   # when done
```

## Read-only? You may not even need a worktree

- **Diff / metadata only:** `glab mr diff <IID> --repo readpeak/<repo>` and
  `glab api projects/readpeak%2F<repo>/repository/files/<path>/raw?ref=<branch>`
  need no local tree at all.
- **Read one file at the MR SHA in place:**
  `git -C /var/lib/code/readpeak/<repo> show "$SHA:<path>"`.

## Do not

- `git clone …readpeak/<repo>…` into `~/Repos`, `~/code`, `/tmp`, a session
  workspace, or a per-MR directory. The repo already exists — make a worktree.
- `glab mr checkout <IID>` in a fresh/empty directory (that re-fetches the whole
  repo). Fetch the MR ref into `/var/lib/code/readpeak/<repo>` and add a
  worktree instead.
- `git checkout <mr-branch>` directly in the shared `/var/lib/code/readpeak/<repo>`
  checkout — that switches the branch everyone shares and fights repo-sync. Use
  a worktree so your branch is isolated.

## Housekeeping

- Name worktrees predictably: `mr-<IID>` or `<branch-name>`. Remove them when
  the task is done (`git -C <repo> worktree remove <path>`); run
  `git -C <repo> worktree prune` if a directory was deleted manually.
