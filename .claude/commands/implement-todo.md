---
description: Take the first open item in todo.md, fix it test-first, refactor, review, commit, mark done, repeat. Laptop only; never EC2, never push.
---

Implement items from todo.md one at a time, test-first, until I stop you or every unblocked item is done. Run without asking questions. Make every decision yourself and log it.

Repo rules:
- todo.md and BACKLOG.md are gitignored working files. BACKLOG.md holds findings (what is wrong, evidence, status); todo.md holds the plan. Edit both freely; never `git add -f` them.
- Allowed: nix eval/build, nix flake check, home-manager build, home-manager switch --flake .#orre (this laptop only), python -m unittest, systemctl --user status/cat/show, journalctl --user, git commit.
- Never: git push, `git worktree remove` on a worktree you did not create, anything touching the EC2 host (nixos-rebuild, ssh kirocrew, launch-ec2), nix flake update, editing permission settings. Items needing those are blocked (see step 7).
- Pre-push hook runs `nix flake check`; keep it green at every commit.

Concurrency: a planner loop (/plan-todo) may rewrite todo.md while you work. It preserves lines marked `[x]`, `[-]` and `[~]` verbatim and only reshapes `[ ]` items.
- At the start of every iteration re-read todo.md from disk; it may have been reordered or split since your last look.
- The moment you pick an item, change its `- [ ]` to `- [~]` with the Edit tool so the planner leaves it alone. Mark it `[x]` or `[-]` before picking the next one; never leave two `[~]` items.
- Edit todo.md and BACKLOG.md with targeted Edit calls on lines you just re-read, never by rewriting the whole file.
- Several implementers may run at once (other terminals, other sessions). Each works in its own git worktree, so nobody sees another's half-finished edits. Never edit, stage, commit or revert files in the main checkout (`/home/orre/.config/home-manager`) except via the integrate step below; its uncommitted changes belong to the human or another loop.
- Claim: marking an item `[~]` is the lock. Write `- [~] ... (wt: <name>)` where `<name>` is your worktree name. Never pick an item that already has `[~]`; skip to the next `[ ]`. Re-read todo.md right after claiming; if another implementer's claim landed on the same item first, release yours and pick again. A `[~]` with no live worktree (`git worktree list`) is stale: ignore it, report it, do not take it over.
- todo.md and BACKLOG.md live only in the main checkout (they are gitignored). Always edit them by absolute path there, never a copy in your worktree. When appending a new BACKLOG ID, re-read the file's tail first and take the next free ID at that moment; another implementer may have taken it.

Loop, per item:

0. Worktree. Once per run: `git worktree add ../hm-wt-$$ -b impl/wt-$$ main` (name = `hm-wt-<pid>`), and do all code work, tests and `nix flake check` there. For every later item, first `git rebase main` in the worktree so you build on the other implementers' commits.

1. Pick. Take the first `- [ ]` in todo.md, reading top to bottom, skipping items another implementer has claimed with `[~]`. If it is a parent with sub-tasks, take the first unchecked sub-task. Mark it `[~] ... (wt: <name>)`. Read its BACKLOG.md entry by ID. Re-verify the claim against the current code and record the result; if already fixed, mark it `[x] already fixed: <evidence>` (and flip BACKLOG.md) and go to 1.

2. Red. Write a test that fails because of the defect, and nothing else. Choose the narrowest fitting kind:
   - a flake check in flake.nix (`checks.x86_64-linux.<id>-<slug>`): `pkgs.runCommand` asserting on rendered config, e.g. `nix eval --raw` of `config.home.file.<path>.text`, `config.systemd.user.services.<unit>.Service.*`, `config.programs.*`, or the generated unit text; fail with a clear message.
   - a `unittest` in nixos/tests/ for Python helpers.
   - a shell test under tests/ run by a flake check, for scripts like update.sh (run the script against a fixture, assert exit code and output).
   - for docs-only or comment-only items (D*): no test; a grep that fails on the stale text counts.
   Run it. It must fail. Paste the failing line into your log. If you cannot make it fail, the claim is wrong or untestable: say which, mark the item accordingly, go to 1.

3. Green. Make the smallest change that passes the test. Run the test, then `nix flake check`. Both must pass. Nothing else changes.

4. Refactor. Only within the files you touched: remove duplication your fix exposed, fix names, delete comments the fix made stale. Rerun the test and `nix flake check`.

5. Verify in place when possible. Never run `home-manager switch` from a worktree: concurrent switches race and would activate unmerged code. Use `home-manager build` and the checks; leave the switch to the human and say so in the report. If the item is about runtime behaviour on this laptop (user units, shell, editor), run `home-manager switch --flake .#orre` and confirm the live effect with the command the BACKLOG entry used (systemctl show, journalctl, zsh -c, nvim --headless …). Record the before/after output. If verification needs EC2, darwin or a devcontainer, say so and record what you could check.

6. Review. Read the full diff with `git diff`. For each concern: if it is in scope, fix it now and rerun; if it is a new defect out of scope, append it to BACKLOG.md with the next free ID in its series (S/C/O/T/D), file:line, evidence, and *(verified)* only if you reproduced it, then add a one-line `- [ ]` task for it at the end of the matching section of todo.md. Never renumber or delete existing IDs.

7. Blocked. If the item needs the EC2 host, credentials, darwin, or a human decision that changes behaviour for other people, mark it `- [-] blocked: <exact reason>` in todo.md, leave the code untouched, and go to 1. Do not block on preference: pick the smaller, safer, code-removing option and log it.

8. Commit. One commit per item in your worktree: Conventional Commit, subject under 50 chars, body naming the BACKLOG ID and the test. `git status` in the worktree must be clean afterwards.

8b. Integrate. `git rebase main` in the worktree; if it conflicts, `git rebase --abort`, mark the item `[-] blocked: rebase conflict with <files>` and go to 1. If main moved, rerun `nix flake check` on the rebased tree. Then `git -C /home/orre/.config/home-manager merge --ff-only impl/<branch>`. If that refuses (main checkout has uncommitted changes to the same files, or main is not an ancestor), leave the branch, mark the item `[x] <text> — <hash> (on branch impl/<branch>, not merged)` and say so in the report. Never use `--force`, `reset` or `stash` on the main checkout. Never push.

9. Mark done. In todo.md change the item to `- [x] <text> — <short hash>`; in BACKLOG.md change its `[ ]` to `[x]` with the hash. Then go to 1.

Stop when: no unclaimed `[ ]` items remain; or `nix flake check` fails and two attempts do not fix it (then revert your tracked-file changes with `git checkout -- <files you touched>`, mark the item blocked with the error, and stop); or you have completed 10 items (then stop and report).

At the end, remove your worktree if all its commits are merged (`git worktree remove`, `git branch -d`); otherwise keep it and name it in the report.

Report at the end, under 15 lines: items done with hashes, items blocked with reasons, new BACKLOG IDs added, and the one command I should run next.

Style: terse, file:line references, no filler. Code, tests and commit messages: normal prose.
