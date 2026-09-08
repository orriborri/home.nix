"""Install complete KiroCrew skill directories from a managed source."""

import argparse
from collections import Counter
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import tempfile
import sys


def fingerprint(directory):
    entries = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlinks are not supported in managed skills: {path}")
        relative = path.relative_to(directory).as_posix()
        if path.is_dir():
            entries.append((relative, "directory", path.stat().st_mode & 0o777))
        elif path.is_file():
            entries.append(
                (
                    relative,
                    path.stat().st_mode & 0o777,
                    hashlib.sha256(path.read_bytes()).hexdigest(),
                )
            )
        else:
            raise ValueError(f"Not a regular resource: {path}")
    return hashlib.sha256(json.dumps(entries).encode()).hexdigest()


def stage_skill(source, destination):
    # Shared code checkouts inherit setgid directories. Copy only ordinary
    # permissions: systemd RestrictSUIDSGID rejects copying those special bits.
    destination.mkdir()
    directories = [(source, destination)]
    for path in sorted(source.rglob("*")):
        target = destination / path.relative_to(source)
        if path.is_symlink():
            raise ValueError(f"Source changed to a symlink: {path}")
        if path.is_dir():
            target.mkdir()
            directories.append((path, target))
        elif path.is_file():
            shutil.copyfile(path, target)
            metadata = path.stat()
            target.chmod(metadata.st_mode & 0o777)
            os.utime(target, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        else:
            raise ValueError(f"Not a regular resource: {path}")
    for path, target in reversed(directories):
        metadata = path.stat()
        target.chmod(metadata.st_mode & 0o777)
        os.utime(target, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))


def safe_path(path):
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Expected an absolute path without traversal: {path}")
    for component in [path, *path.parents]:
        if component.is_symlink():
            raise ValueError(f"Refusing symlink path: {component}")
    return path


def valid_name(name):
    path = Path(name)
    if (
        not name
        or not path.parts
        or path.is_absolute()
        or path.as_posix() != name
        or any(part.startswith(".") for part in path.parts)
    ):
        raise ValueError(f"Invalid skill path: {name!r}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument(
        "--revision", help="Require this commit SHA and an unchanged source subtree"
    )
    parser.add_argument(
        "--archive-legacy",
        action="store_true",
        help="Archive identical old flattened files",
    )
    args = parser.parse_args()
    if args.revision:
        if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
            raise ValueError("Revision must be a full lowercase commit SHA")

        def git(*arguments):
            return subprocess.check_output(
                ["git", "-C", str(args.source), *arguments],
                text=True,
            ).strip()

        if git("rev-parse", "HEAD") != args.revision or git(
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignored=matching",
            "--",
            ".",
        ):
            raise ValueError("Skills source does not match the clean pinned revision")
    roots = [safe_path(path) for path in (args.source, args.destination, args.state)]
    for i, path in enumerate(roots):
        if any(
            path.is_relative_to(other) or other.is_relative_to(path)
            for other in roots[i + 1 :]
        ):
            raise ValueError(
                "Source, destination and state directories must not overlap"
            )
    sources = {}

    def walk_error(error):
        raise error

    for directory, directories, files in os.walk(args.source, onerror=walk_error):
        directories[:] = sorted(
            name for name in directories if not name.startswith(".")
        )
        for name in directories + files:
            if (Path(directory) / name).is_symlink():
                raise ValueError(f"Refusing source symlink: {Path(directory) / name}")
        if "SKILL.md" in files:
            name = Path(directory).relative_to(args.source).as_posix()
            valid_name(name)
            sources[name] = Path(directory)
    if not sources:
        raise ValueError(
            f"No skills found at {args.source}; preserving installed skills"
        )
    args.state.mkdir(parents=True, exist_ok=True)
    lock = safe_path(args.state / "sync.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX)
    manifest = args.state / "manifest.json"
    safe_path(manifest)
    safe_path(args.state / "manifest.pending")
    managed = json.loads(manifest.read_text()) if manifest.exists() else {}
    if not isinstance(managed, dict):
        raise ValueError("Invalid ownership manifest")
    names = set(sources) | set(managed)
    for name in names:
        relative = valid_name(name)
        destination = safe_path(args.destination / relative)
        if any(parent.as_posix() in names for parent in relative.parents):
            raise ValueError(f"Overlapping skill directories: {name}")
        for parent in destination.parents:
            if parent == args.destination:
                break
            if (parent / "SKILL.md").exists():
                raise ValueError(f"Destination is inside an existing skill: {parent}")
    # Validate every source before publishing any changes.
    digests = {name: fingerprint(source) for name, source in sources.items()}
    conflicts = []
    for name, source in sources.items():
        destination = args.destination / name
        digest = digests[name]
        if destination.exists():
            if (
                name not in managed
                or not destination.is_dir()
                or fingerprint(destination) != managed[name]
            ):
                conflicts.append(name)
                continue
            if managed[name] == digest:
                continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        transaction = Path(tempfile.mkdtemp(prefix="transaction-", dir=args.state))
        (transaction / "metadata.json").write_text(
            json.dumps({"name": name, "previous": managed.get(name)})
        )
        stage = transaction / "skill"
        stage_skill(source, stage)
        if fingerprint(stage) != digest:
            raise ValueError(
                f"Source changed while staging {name}; preserving destination"
            )
        previous = transaction / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise
        managed[name] = digest
        pending = args.state / "manifest.pending"
        pending.write_text(json.dumps(managed, indent=2) + "\n")
        pending.replace(manifest)
        print(f"Installed {name}")
    for name in sorted(managed.keys() - sources.keys()):
        destination = args.destination / name
        if destination.exists():
            if not destination.is_dir() or fingerprint(destination) != managed[name]:
                conflicts.append(name)
                continue
            transaction = Path(tempfile.mkdtemp(prefix="removed-", dir=args.state))
            (transaction / "metadata.json").write_text(
                json.dumps({"name": name, "previous": managed[name]})
            )
            destination.rename(transaction / "previous")
        del managed[name]
        pending = args.state / "manifest.pending"
        pending.write_text(json.dumps(managed, indent=2) + "\n")
        pending.replace(manifest)
        print(f"Archived removed skill {name}")
    if args.archive_legacy:
        slugs = Counter(Path(name).name for name in sources)
        for name, source in sources.items():
            if name in conflicts or slugs[Path(name).name] != 1:
                continue
            legacy = args.destination / f"{Path(name).name}.md"
            if legacy.is_symlink() or not legacy.is_file():
                continue
            if legacy.read_bytes() != (source / "SKILL.md").read_bytes():
                continue
            archive = Path(tempfile.mkdtemp(prefix="legacy-", dir=args.state))
            legacy.rename(archive / legacy.name)
            print(f"Archived flattened file {legacy.name} to {archive}")
    if conflicts:
        print("Preserved conflicting skills: " + ", ".join(conflicts), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Skill sync failed: {error}", file=sys.stderr)
        sys.exit(1)
