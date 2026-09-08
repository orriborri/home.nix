"""Fetch immutable repository revisions and install them without forcing worktrees."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


def git(directory, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(directory), *arguments],
        text=True,
    ).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("fetch", "checkout"))
    parser.add_argument("--remote", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        raise ValueError("Revision must be a full lowercase commit SHA")
    ref = f"refs/kirocrew/pins/{args.revision}"
    destination = args.destination
    if not destination.exists():
        destination.mkdir(parents=True)
        git(destination, "init", *(["--bare"] if args.operation == "fetch" else []))
    if args.operation == "fetch":
        if git(destination, "rev-parse", "--is-bare-repository") != "true":
            raise ValueError("Pinned mirror must be a bare repository")
        git(
            destination,
            "fetch",
            "--depth=1",
            "--no-tags",
            "--",
            args.remote,
            f"{args.revision}:{ref}",
        )
    else:
        if not (destination / ".git").is_dir():
            raise ValueError("Checkout must have its own Git directory")
        head = subprocess.run(
            ["git", "-C", str(destination), "rev-parse", "--verify", "HEAD"],
            capture_output=True,
            text=True,
        )
        if head.returncode == 0 and head.stdout.strip() == args.revision:
            print(f"Already at {args.revision}; preserving checkout: {destination}")
            return
        if git(destination, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError(f"Preserving dirty checkout: {destination}")
        if head.returncode == 0 and head.stdout.strip() != args.revision:
            previous = subprocess.run(
                [
                    "git",
                    "-C",
                    str(destination),
                    "rev-parse",
                    "--verify",
                    "refs/kirocrew/installed",
                ],
                capture_output=True,
                text=True,
            )
            if previous.returncode == 0:
                if previous.stdout.strip() != head.stdout.strip():
                    raise ValueError(f"Preserving locally changed HEAD: {destination}")
            else:
                upstream = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(destination),
                        "rev-parse",
                        "--verify",
                        "@{upstream}",
                    ],
                    capture_output=True,
                    text=True,
                )
                if (
                    upstream.returncode != 0
                    or upstream.stdout.strip() != head.stdout.strip()
                ):
                    raise ValueError(
                        f"Preserving checkout without a matching upstream: {destination}"
                    )
        git(
            destination,
            "fetch",
            "--depth=1",
            "--update-shallow",
            "--no-tags",
            "--",
            args.remote,
            f"{ref}:{ref}",
        )
        if git(destination, "rev-parse", f"{ref}^{{commit}}") != args.revision:
            raise ValueError("Fetched commit does not match requested revision")
        git(destination, "checkout", "--detach", args.revision)
        git(destination, "update-ref", "refs/kirocrew/installed", args.revision)
    if git(destination, "rev-parse", f"{ref}^{{commit}}") != args.revision:
        raise ValueError("Fetched commit does not match requested revision")
    print(f"{args.operation}: {destination} at {args.revision}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Pinned repository sync failed: {error}", file=sys.stderr)
        sys.exit(1)
