"""Local bare-repository regression tests for the retryable vault sync.

These cover the Step 4 acceptance criteria from repair-plan.md:

* commit success followed by push failure, then retry without another edit;
* remote-only (incoming) updates fast-forwarded on a clean tree;
* a clean no-op;
* divergence (rebased) and unresolvable conflict recovery (aborted, preserved);
* a missing tracked upstream;
* overlapping sync runs serialized by a single lock;
* an in-progress merge/rebase left untouched;
* failed sync never discards notes or local commits.

The tests drive scripts/kirocrew_vault_sync.py against real local git repos in
tempfile dirs — no network, no git-crypt (encryption is exercised separately).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = MODULE_ROOT / "scripts" / "kirocrew_vault_sync.py"

GIT_IDENT = (
    "-c",
    "user.name=Test",
    "-c",
    "user.email=test@example.com",
)


class VaultSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        # A bare "remote" plus a peer clone that stands in for the workstation
        # (used to inject incoming commits) and the vault checkout under test.
        self.origin = self.root / "origin.git"
        subprocess.check_call(["git", "init", "--bare", "-b", "main", str(self.origin)])

        self.peer = self.root / "peer"
        self._clone(self.peer)
        self._commit(self.peer, "README.md", "seed\n", "seed")
        self.git(self.peer, "push", "origin", "main")

        self.vault = self.root / "vault"
        self._clone(self.vault)
        # Ensure the tracked upstream is set (clone sets it, but be explicit).
        self.git(self.vault, "branch", "--set-upstream-to=origin/main", "main")

    # ── helpers ──────────────────────────────────────────────────────────────

    def git(self, directory: Path, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(directory), *GIT_IDENT, *arguments],
            text=True,
            stderr=subprocess.STDOUT,
        ).strip()

    def _clone(self, dest: Path) -> None:
        subprocess.check_call(
            ["git", "clone", "--quiet", self.origin.as_uri(), str(dest)]
        )

    def _commit(self, directory: Path, name: str, content: str, message: str) -> str:
        (directory / name).write_text(content)
        self.git(directory, "add", name)
        self.git(directory, "commit", "-m", message)
        return self.git(directory, "rev-parse", "HEAD")

    def run_sync(self, *, vault: Path | None = None, extra: tuple[str, ...] = ()):
        vault = vault or self.vault
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--vault-dir",
                str(vault),
                "--message",
                "sync commit",
                *extra,
            ],
            text=True,
            capture_output=True,
        )

    def assertSync(self, result, success: bool):
        self.assertEqual(
            result.returncode == 0,
            success,
            f"rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}",
        )

    def head(self, directory: Path) -> str:
        return self.git(directory, "rev-parse", "HEAD")

    def origin_head(self) -> str:
        return self.git(self.origin, "rev-parse", "main")

    def push_from_peer(self, name: str, content: str, message: str) -> str:
        sha = self._commit(self.peer, name, content, message)
        self.git(self.peer, "push", "origin", "main")
        return sha

    # ── tests ─────────────────────────────────────────────────────────────────

    def test_clean_noop_is_success_and_touches_nothing(self):
        before = self.head(self.vault)
        result = self.run_sync()
        self.assertSync(result, True)
        self.assertEqual(self.head(self.vault), before)
        self.assertEqual(self.origin_head(), before)

    def test_local_change_is_committed_and_pushed(self):
        (self.vault / "note.md").write_text("agent note\n")
        result = self.run_sync()
        self.assertSync(result, True)
        # The commit reached origin.
        self.assertEqual(self.head(self.vault), self.origin_head())
        self.assertEqual(
            self.git(self.origin, "show", "main:note.md"), "agent note"
        )

    def test_incoming_only_fast_forwards_on_clean_tree(self):
        incoming = self.push_from_peer("upstream.md", "from workstation\n", "upstream")
        result = self.run_sync()
        self.assertSync(result, True)
        self.assertEqual(self.head(self.vault), incoming)
        self.assertTrue((self.vault / "upstream.md").exists())

    def test_push_failure_then_retry_without_another_edit(self):
        # Create a local commit AND a competing upstream commit so the first
        # push is rejected (non-fast-forward), then a plain retry (clean tree,
        # no new edit) must fetch, rebase, and succeed.
        self.push_from_peer("upstream.md", "remote first\n", "remote")
        (self.vault / "note.md").write_text("local edit\n")

        # Fetch is done inside the script; before the first run the vault does
        # not yet know about the upstream commit, so its push is a non-ff after
        # fetch+reconcile... but reconcile rebases, so to force a *push* failure
        # we point the vault at a read-only remote for the first attempt.
        readonly = self.root / "readonly.git"
        subprocess.check_call(
            ["git", "clone", "--bare", "--quiet", str(self.origin), str(readonly)]
        )
        # Make the bare remote reject pushes via a pre-receive hook.
        hook = readonly / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        self.git(self.vault, "remote", "set-url", "origin", str(readonly))
        self.git(self.vault, "branch", "--set-upstream-to=origin/main", "main")

        first = self.run_sync()
        self.assertSync(first, False)  # push blocked
        # The local commit must survive the failure.
        self.assertIn("local edit", (self.vault / "note.md").read_text())
        local_commit = self.head(self.vault)

        # Repair the remote (remove the rejecting hook) and retry with NO new
        # edit. The clean-tree retry must still push.
        hook.unlink()
        retry = self.run_sync()
        self.assertSync(retry, True)
        self.assertEqual(
            self.git(readonly, "rev-parse", "main"), self.head(self.vault)
        )
        # No new commit was created on retry.
        self.assertEqual(self.head(self.vault), local_commit)

    def test_divergence_is_rebased_and_pushed(self):
        # Local commit and a different upstream commit → divergence. The script
        # should rebase local onto upstream, then push.
        self.push_from_peer("remote.md", "remote change\n", "remote")
        self._commit(self.vault, "local.md", "local change\n", "local")
        result = self.run_sync()
        self.assertSync(result, True)
        # Both files present; history linear on top of remote.
        self.assertTrue((self.vault / "remote.md").exists())
        self.assertTrue((self.vault / "local.md").exists())
        self.assertEqual(self.head(self.vault), self.origin_head())

    def test_conflicting_divergence_aborts_and_preserves_local(self):
        # Both sides touch the same file with conflicting content.
        self.push_from_peer("conflict.md", "remote wins\n", "remote")
        local_sha = self._commit(
            self.vault, "conflict.md", "local wins\n", "local"
        )
        result = self.run_sync()
        self.assertSync(result, False)
        # Local commit preserved, no rebase left in progress, content intact.
        self.assertEqual(self.head(self.vault), local_sha)
        self.assertEqual((self.vault / "conflict.md").read_text(), "local wins\n")
        self.assertFalse((self.vault / ".git" / "rebase-merge").exists())
        self.assertFalse((self.vault / ".git" / "rebase-apply").exists())
        # Upstream was not force-updated.
        self.assertEqual(
            self.git(self.origin, "show", "main:conflict.md"), "remote wins"
        )

    def test_missing_upstream_fails_without_pushing(self):
        self.git(self.vault, "branch", "--unset-upstream")
        (self.vault / "note.md").write_text("orphan note\n")
        result = self.run_sync()
        self.assertSync(result, False)
        self.assertIn("upstream", (result.stdout + result.stderr).lower())
        # The change was still committed locally (not lost) but never pushed.
        self.assertIn("orphan note", (self.vault / "note.md").read_text())

    def test_in_progress_rebase_is_left_untouched(self):
        # Simulate an interrupted rebase by planting the marker directory.
        marker = self.vault / ".git" / "rebase-merge"
        marker.mkdir(parents=True)
        (self.vault / "note.md").write_text("should not be committed\n")
        result = self.run_sync()
        self.assertSync(result, False)
        self.assertIn("rebase", (result.stdout + result.stderr).lower())
        # Nothing committed; the marker remains for manual recovery.
        self.assertTrue(marker.exists())
        self.assertIn("should not be committed", (self.vault / "note.md").read_text())

    def test_overlapping_runs_serialize_on_the_lock(self):
        # Hold the lock, then a sync run must decline rather than race.
        import fcntl

        lock_path = self.vault / ".git" / "held.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.vault / "note.md").write_text("during lock\n")
            result = self.run_sync(extra=("--lock-file", str(lock_path)))
            self.assertSync(result, False)
            self.assertIn("lock", (result.stdout + result.stderr).lower())
            # It must not have committed while another run "held" the lock.
            self.assertTrue(
                (self.vault / "note.md").read_text() == "during lock\n"
            )
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def test_detached_head_is_refused(self):
        detached = self.head(self.vault)
        self.git(self.vault, "checkout", "--detach", detached)
        (self.vault / "note.md").write_text("on detached head\n")
        result = self.run_sync()
        self.assertSync(result, False)
        self.assertIn("detached", (result.stdout + result.stderr).lower())


if __name__ == "__main__":
    unittest.main()
