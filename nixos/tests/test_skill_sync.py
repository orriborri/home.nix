import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "kirocrew_skill_sync.py"


class SkillSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.destination = self.root / "skills"
        self.state = self.root / "state"
        self.skill = self.source / "engineering" / "tdd"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text("---\nname: tdd\n---\nTest first.\n")

    def sync(self, success=True, extra=()):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--state",
                str(self.state),
                *extra,
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_installs_nested_skill_with_executable_resources(self):
        scripts = self.skill / "scripts"
        scripts.mkdir()
        (scripts / "check.sh").write_text("#!/bin/sh\nexit 0\n")
        (scripts / "check.sh").chmod(0o755)
        self.sync()
        installed = self.destination / "engineering" / "tdd"
        self.assertEqual(
            (installed / "SKILL.md").read_text(), "---\nname: tdd\n---\nTest first.\n"
        )
        self.assertEqual(
            (installed / "scripts/check.sh").read_text(), "#!/bin/sh\nexit 0\n"
        )
        self.assertTrue(os.access(installed / "scripts/check.sh", os.X_OK))

    def test_reconciles_resources_and_removals_without_rewriting_unchanged_skills(self):
        resource = self.skill / "reference.txt"
        resource.write_text("old reference")
        (self.skill / "obsolete.txt").write_text("remove me")
        self.sync()
        installed = self.destination / "engineering/tdd"
        before = (installed / "SKILL.md").stat().st_ino
        self.sync()
        self.assertEqual((installed / "SKILL.md").stat().st_ino, before)
        resource.write_text("new reference")
        (self.skill / "obsolete.txt").unlink()
        self.sync()
        self.assertEqual((installed / "reference.txt").read_text(), "new reference")
        self.assertFalse((installed / "obsolete.txt").exists())

    def test_preserves_user_edits_and_unmanaged_collisions(self):
        self.sync()
        installed = self.destination / "engineering/tdd/SKILL.md"
        installed.write_text("User's edited instructions")
        (self.skill / "SKILL.md").write_text("Upstream update")
        self.sync(success=False)
        self.assertEqual(installed.read_text(), "User's edited instructions")
        other = self.source / "custom"
        other.mkdir()
        (other / "SKILL.md").write_text("upstream")
        (self.destination / "custom").mkdir()
        (self.destination / "custom/SKILL.md").write_text("local skill")
        self.sync(success=False)
        self.assertEqual(
            (self.destination / "custom/SKILL.md").read_text(), "local skill"
        )

    def test_removes_only_unchanged_managed_skills_and_preserves_missing_sources(self):
        other = self.source / "other"
        other.mkdir()
        (other / "SKILL.md").write_text("Another skill")
        self.sync()
        shutil.rmtree(self.skill)
        self.sync()
        self.assertFalse((self.destination / "engineering/tdd").exists())
        self.assertTrue(list(self.state.rglob("previous/SKILL.md")))
        shutil.rmtree(self.source)
        self.sync(success=False)
        self.assertEqual(
            (self.destination / "other/SKILL.md").read_text(), "Another skill"
        )

    def test_rejects_links_and_unsafe_state_without_touching_external_files(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "SKILL.md").write_text("untouched")
        (self.skill / "escape").symlink_to(outside, target_is_directory=True)
        self.sync(success=False)
        (self.skill / "escape").unlink()
        self.destination.mkdir(exist_ok=True)
        (self.destination / "engineering").symlink_to(outside, target_is_directory=True)
        self.sync(success=False)
        self.assertFalse((outside / "tdd").exists())
        (self.destination / "engineering").unlink()
        self.state.mkdir(exist_ok=True)
        (self.state / "manifest.json").write_text('{"../outside": "bogus"}')
        self.sync(success=False)
        self.assertEqual((outside / "SKILL.md").read_text(), "untouched")

    def test_refuses_wrong_revision_and_dirty_pinned_source(self):
        def git(*arguments):
            return subprocess.check_output(
                ["git", "-C", str(self.source), *arguments],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()

        git("init")
        git("add", ".")
        git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "skills",
        )
        revision = git("rev-parse", "HEAD")
        self.sync(success=False, extra=("--revision", "0" * 40))
        self.assertFalse(self.destination.exists())
        self.sync(extra=("--revision", revision))
        (self.skill / "SKILL.md").write_text("uncommitted source")
        self.sync(success=False, extra=("--revision", revision))
        self.assertIn(
            "Test first.", (self.destination / "engineering/tdd/SKILL.md").read_text()
        )

    def test_archives_only_identical_unambiguous_flattened_files(self):
        self.destination.mkdir()
        legacy = self.destination / "tdd.md"
        legacy.write_text((self.skill / "SKILL.md").read_text())
        (self.destination / "notes.md").write_text("personal notes")
        self.sync(extra=("--archive-legacy",))
        self.assertFalse(legacy.exists())
        self.assertEqual((self.destination / "notes.md").read_text(), "personal notes")
        self.assertTrue(list(self.state.rglob("tdd.md")))

    def test_rejects_root_skill_without_replacing_destination(self):
        shutil.rmtree(self.source)
        self.source.mkdir()
        (self.source / "SKILL.md").write_text("invalid root skill")
        self.sync(success=False)
        self.assertFalse(self.destination.exists())

    def test_copies_shared_checkout_permissions_without_special_mode_bits(self):
        self.skill.chmod(0o2775)
        resource = self.skill / "run.sh"
        resource.write_text("#!/bin/sh\nexit 0\n")
        resource.chmod(0o4755)
        self.sync()
        installed = self.destination / "engineering/tdd"
        self.assertEqual(installed.stat().st_mode & 0o7777, 0o775)
        self.assertEqual((installed / "run.sh").stat().st_mode & 0o7777, 0o755)

    def test_pinned_source_ignores_changes_outside_skills_but_rejects_ignored_resources(
        self,
    ):
        def git(*arguments):
            return subprocess.check_output(
                ["git", "-C", str(self.root), *arguments],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()

        git("init")
        (self.root / ".gitignore").write_text("source/**/ignored.txt\n")
        git("add", "source", ".gitignore")
        git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "skills",
        )
        revision = git("rev-parse", "HEAD")
        (self.root / ".kiro").mkdir()
        (self.root / ".kiro/agent.json").write_text("{}")
        self.sync(extra=("--revision", revision))
        (self.skill / "ignored.txt").write_text("not part of pinned commit")
        self.sync(success=False, extra=("--revision", revision))


if __name__ == "__main__":
    unittest.main()
