from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/kirocrew_pinned_repo.py"


class PinnedRepoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.origin = self.root / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-b", "main")
        self.git(self.origin, "config", "user.name", "Test")
        self.git(self.origin, "config", "user.email", "test@example.com")
        self.first = self.commit("first")
        self.second = self.commit("second")
        self.mirror = self.root / "mirror.git"
        self.checkout = self.root / "checkout"

    def git(self, directory, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(directory), *arguments],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()

    def commit(self, content):
        (self.origin / "README.md").write_text(content)
        self.git(self.origin, "add", ".")
        self.git(self.origin, "commit", "-m", content)
        return self.git(self.origin, "rev-parse", "HEAD")

    def run_helper(self, operation, revision, success=True):
        remote = self.origin.as_uri() if operation == "fetch" else str(self.mirror)
        destination = self.mirror if operation == "fetch" else self.checkout
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                operation,
                "--remote",
                remote,
                "--destination",
                str(destination),
                "--revision",
                revision,
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_fetches_old_commit_and_updates_detached_checkout_from_shallow_mirror(self):
        self.run_helper("fetch", self.first)
        self.run_helper("checkout", self.first)
        self.assertEqual((self.checkout / "README.md").read_text(), "first")
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.first)
        self.assertEqual(
            self.git(self.mirror, "rev-parse", "--is-shallow-repository"), "true"
        )
        self.run_helper("fetch", self.second)
        self.run_helper("checkout", self.second)
        self.assertEqual((self.checkout / "README.md").read_text(), "second")
        self.run_helper("checkout", self.second)

    def test_dirty_checkout_and_unavailable_revision_preserve_installed_content(self):
        self.run_helper("fetch", self.first)
        self.run_helper("checkout", self.first)
        (self.checkout / "README.md").write_text("local edits")
        self.run_helper("fetch", self.second)
        self.run_helper("checkout", self.second, success=False)
        self.assertEqual((self.checkout / "README.md").read_text(), "local edits")
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.first)
        self.run_helper("fetch", "0" * 40, success=False)
        self.assertEqual(
            self.git(self.mirror, "rev-parse", f"refs/kirocrew/pins/{self.first}"),
            self.first,
        )

    def test_preserves_local_commits_on_detached_checkout(self):
        self.run_helper("fetch", self.first)
        self.run_helper("checkout", self.first)
        (self.checkout / "local.txt").write_text("local work")
        self.git(self.checkout, "add", ".")
        self.git(
            self.checkout,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "local",
        )
        local_head = self.git(self.checkout, "rev-parse", "HEAD")
        self.run_helper("fetch", self.second)
        self.run_helper("checkout", self.second, success=False)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), local_head)
        self.assertEqual((self.checkout / "local.txt").read_text(), "local work")

    def test_matching_revision_is_a_noop_with_unrelated_local_files(self):
        self.run_helper("fetch", self.first)
        self.run_helper("checkout", self.first)
        (self.checkout / ".kiro").mkdir()
        (self.checkout / ".kiro/agent.json").write_text("local state")
        self.run_helper("checkout", self.first)
        self.assertEqual(
            (self.checkout / ".kiro/agent.json").read_text(), "local state"
        )


if __name__ == "__main__":
    unittest.main()
