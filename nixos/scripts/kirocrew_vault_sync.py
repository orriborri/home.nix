"""Retryable synchronization for the KiroCrew git-crypt vault.

This implements the Step 4 sync loop from repair-plan.md. It runs on a timer as
the ``kirocrew`` user and must be safe to run repeatedly and concurrently with
application writers (KiroCrew agents and Obsidian).

Design invariants (repair-plan.md Step 4):

* Commit only when the working tree has changes, but fetch/reconcile/push
  independently of whether a new commit was needed. A failed push is retried on
  the next run even when the checkout is clean.
* Detect outgoing commits separately from uncommitted files.
* Apply incoming fast-forward updates when there are no local edits. Handle
  divergent history conservatively: preserve local work and report a conflict
  rather than reset/clean/force-push.
* Use one lock across clone and sync so overlapping timer runs cannot collide,
  and detect an in-progress merge/rebase instead of interfering with manual
  recovery.
* Validate the tracked upstream and the push destination instead of assuming
  every checkout is on the intended branch.

The script never resets, cleans, or force-pushes. On any ambiguous state it
exits non-zero, leaving the working tree and any local commits untouched so the
next timer run (or a human) can reconcile.

The git-crypt unlock and secret/askpass wiring stay in the Nix module; this
script only manipulates an already-initialized (and, for content, already
unlocked) working tree via the ``GIT_*`` environment it inherits.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterator, Optional


class SyncError(RuntimeError):
    """A condition that should fail the run but leave state intact for retry."""


def _run(
    directory: Path,
    *arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        text=True,
        capture_output=True,
        check=check,
    )


def _git(directory: Path, *arguments: str) -> str:
    return _run(directory, *arguments).stdout.strip()


def log(message: str) -> None:
    print(message, flush=True)


@contextlib.contextmanager
def _lock(lock_path: Path) -> Iterator[None]:
    """Hold an exclusive advisory lock for the duration of the block.

    A single lock guards both clone and sync so overlapping timer runs serialize
    instead of racing. Non-blocking: if another run holds the lock we exit
    cleanly (the holder is already doing the work).
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:  # already held by a concurrent run
            raise SyncError("another vault sync run holds the lock; skipping") from exc
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(handle, fcntl.LOCK_UN)
        os.close(handle)


def _in_progress_operation(git_dir: Path) -> Optional[str]:
    """Return the name of an in-progress merge/rebase/etc., or None."""
    markers = {
        "MERGE_HEAD": "merge",
        "rebase-merge": "rebase",
        "rebase-apply": "rebase",
        "CHERRY_PICK_HEAD": "cherry-pick",
        "REVERT_HEAD": "revert",
        "BISECT_LOG": "bisect",
    }
    for marker, name in markers.items():
        if (git_dir / marker).exists():
            return name
    return None


def _has_uncommitted_changes(directory: Path) -> bool:
    return bool(_git(directory, "status", "--porcelain"))


def _current_branch(directory: Path) -> str:
    # `symbolic-ref --quiet` exits non-zero on a detached HEAD, so don't let the
    # check=True default turn that into a generic CalledProcessError.
    result = _run(directory, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    branch = result.stdout.strip()
    if result.returncode != 0 or not branch:
        raise SyncError("HEAD is detached; refusing to sync a detached checkout")
    return branch


def _tracked_upstream(directory: Path) -> str:
    """The configured @{upstream}, e.g. 'origin/main'. Fail if unset."""
    result = _run(
        directory,
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{upstream}",
        check=False,
    )
    upstream = result.stdout.strip()
    if result.returncode != 0 or not upstream:
        raise SyncError(
            "no tracked upstream for the current branch; refusing to guess a "
            "push destination"
        )
    return upstream


def _counts_vs_upstream(directory: Path, upstream: str) -> tuple[int, int]:
    """Return (ahead, behind) commit counts of HEAD relative to upstream."""
    out = _git(directory, "rev-list", "--left-right", "--count", f"HEAD...{upstream}")
    ahead_str, behind_str = out.split()
    return int(ahead_str), int(behind_str)


def _commit_if_dirty(directory: Path, message: str) -> bool:
    """Commit working-tree changes. Returns True if a commit was created."""
    if not _has_uncommitted_changes(directory):
        return False
    _run(directory, "add", "-A")
    # A concurrent writer could have reverted the tree between the check and the
    # add; re-check via the staged diff so we never create an empty commit.
    staged = _run(directory, "diff", "--cached", "--quiet", check=False)
    if staged.returncode == 0:
        return False
    _run(directory, "commit", "-m", message)
    return True


def _reconcile(directory: Path, upstream: str, had_local_commit: bool) -> None:
    """Integrate incoming commits conservatively.

    * No incoming commits: nothing to do.
    * Incoming only, and we are not ahead: fast-forward.
    * We are ahead with no incoming: nothing to integrate (push handles it).
    * Divergence (ahead and behind): rebase local commits onto upstream. Abort
      and report on conflict, preserving local work.
    """
    ahead, behind = _counts_vs_upstream(directory, upstream)

    if behind == 0:
        return

    if ahead == 0:
        # Pure fast-forward. Only safe with a clean tree.
        if _has_uncommitted_changes(directory):
            raise SyncError(
                "incoming updates but the working tree has uncommitted local "
                "edits; leaving them in place to reconcile next run"
            )
        _run(directory, "merge", "--ff-only", upstream)
        log(f"Fast-forwarded {behind} incoming commit(s) from {upstream}.")
        return

    # Divergent: ahead > 0 and behind > 0. Rebase our commits onto upstream.
    if _has_uncommitted_changes(directory):
        raise SyncError(
            "history diverged and the working tree is dirty; refusing to rebase "
            "over uncommitted edits"
        )
    rebase = _run(directory, "rebase", upstream, check=False)
    if rebase.returncode != 0:
        _run(directory, "rebase", "--abort", check=False)
        raise SyncError(
            "divergent history could not be rebased cleanly; aborted and left "
            "local commits intact for manual resolution"
        )
    log(f"Rebased local commit(s) onto {behind} incoming commit(s) from {upstream}.")


def _push(directory: Path, branch: str, upstream: str) -> None:
    """Push outgoing commits to the tracked upstream's branch."""
    ahead, _ = _counts_vs_upstream(directory, upstream)
    if ahead == 0:
        log("Nothing to push; local branch is not ahead of upstream.")
        return
    # upstream is 'remote/branch'; split once from the left.
    remote, _, remote_branch = upstream.partition("/")
    if not remote or not remote_branch:
        raise SyncError(f"malformed upstream ref: {upstream!r}")
    push = _run(
        directory,
        "push",
        remote,
        f"HEAD:refs/heads/{remote_branch}",
        check=False,
    )
    if push.returncode != 0:
        # Non-fast-forward or transient failure. Do not force. Leave the commit
        # so the next run fetches, reconciles, and retries.
        raise SyncError(
            f"push to {remote}/{remote_branch} failed; will retry next run:\n"
            f"{push.stderr.strip()}"
        )
    log(f"Pushed {ahead} commit(s) to {remote}/{remote_branch} (branch {branch}).")


def sync(directory: Path, *, message: str, lock_path: Path) -> int:
    git_dir = directory / ".git"
    if not git_dir.exists():
        log(f"Vault repo not initialized at {directory}; run clone first.")
        return 1

    try:
        with _lock(lock_path):
            in_progress = _in_progress_operation(git_dir)
            if in_progress:
                raise SyncError(
                    f"a git {in_progress} is in progress; leaving it for manual "
                    "recovery"
                )

            branch = _current_branch(directory)
            upstream = _tracked_upstream(directory)
            remote = upstream.partition("/")[0]

            # 1. Commit local edits (only if there are any).
            committed = _commit_if_dirty(directory, message)
            if committed:
                log("Committed local vault changes.")
            else:
                log("No local changes to commit.")

            # 2. Always fetch — independent of whether we committed. This is what
            #    makes a previously-failed push retry on a now-clean tree.
            fetch = _run(directory, "fetch", "--prune", remote, check=False)
            if fetch.returncode != 0:
                raise SyncError(
                    f"fetch from {remote} failed; will retry next run:\n"
                    f"{fetch.stderr.strip()}"
                )

            # 3. Integrate incoming commits conservatively.
            _reconcile(directory, upstream, committed)

            # 4. Push any outgoing commits (including ones left by an earlier
            #    failed push).
            _push(directory, branch, upstream)
        return 0
    except SyncError as exc:
        log(f"vault sync: {exc}")
        return 1
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        log(f"vault sync: git command failed: {' '.join(exc.cmd)}\n{detail}")
        return 1


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--vault-dir",
        type=Path,
        required=True,
        help="Path to the vault working tree.",
    )
    parser.add_argument(
        "--message",
        default=None,
        help="Commit message for local changes (default: timestamped).",
    )
    parser.add_argument(
        "--lock-file",
        type=Path,
        default=None,
        help="Advisory lock path (default: <vault-dir>/.git/kirocrew-sync.lock).",
    )
    args = parser.parse_args(argv)

    vault_dir: Path = args.vault_dir
    message = args.message
    if message is None:
        from datetime import datetime, timezone

        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        message = f"KiroCrew vault update {stamp}"

    lock_file = args.lock_file or (vault_dir / ".git" / "kirocrew-sync.lock")
    return sync(vault_dir, message=message, lock_path=lock_file)


if __name__ == "__main__":
    sys.exit(main())
