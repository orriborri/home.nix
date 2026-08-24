"""CLI argument parsing for the EC2 launcher."""
from __future__ import annotations

import argparse
from typing import Sequence

from .models import COMMANDS, Arguments, LauncherError

# Browser shortcuts: `./launch-ec2 firefox` → command=browser, browser_app=firefox
BROWSER_SHORTCUTS = {"firefox", "chromium"}


def parse_arguments(argv: Sequence[str]) -> Arguments:
    aliases = {
        "--portal": "portal",
        "--stop": "stop",
        "--destroy": "destroy",
        "--rebuild": "rebuild",
        "--new": "new",
        "--migrate-kirocrew": "migrate-kirocrew",
        "--sync-state": "sync-state",
        "--browser": "browser",
    }
    normalized = [aliases.get(argument, argument) for argument in argv]

    # Handle browser shortcuts: `firefox` or `chromium` as the first positional
    browser_app: str | None = None
    selected_commands = [argument for argument in normalized if argument in COMMANDS]
    if not selected_commands:
        # Check for browser shortcut
        for i, arg in enumerate(normalized):
            if arg in BROWSER_SHORTCUTS:
                browser_app = arg
                normalized[i] = "browser"
                selected_commands = ["browser"]
                break

    if len(selected_commands) > 1:
        raise LauncherError("Specify exactly one launcher command")
    command = selected_commands[0] if selected_commands else "start"
    if selected_commands:
        normalized.remove(command)

    # If command is "browser" but no shortcut was used, next positional is the app
    if command == "browser" and browser_app is None:
        # Find the browser name in remaining args
        remaining_positionals = [a for a in normalized if not a.startswith("-")]
        if remaining_positionals and remaining_positionals[0] in BROWSER_SHORTCUTS:
            browser_app = remaining_positionals[0]
            normalized.remove(browser_app)
        else:
            browser_app = "firefox"  # default

    parser = argparse.ArgumentParser(
        prog="launch-ec2",
        usage="launch-ec2 [COMMAND] [profile] [region] [instance-type] [ami-id] [OPTIONS]",
        description="Manage the KiroCrew EC2 instance through AWS SSM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "commands:\n"
            "  start              launch or resume and rebuild (default)\n"
            "  portal             start or resume and open http://127.0.0.1:7780\n"
            "  stop               stop the saved instance\n"
            "  destroy            permanently terminate the saved instance\n"
            "  rebuild            rebuild the saved instance\n"
            "  new                launch a new instance\n"
            "  migrate-kirocrew   migrate local KiroCrew state to the instance\n"
            "  sync-state         sync local kirocrew config, skills, and workspace to remote\n"
            "  browser [APP]      open X11-forwarded browser (firefox|chromium, default: firefox)\n"
            "  firefox            shortcut for: browser firefox\n"
            "  chromium           shortcut for: browser chromium"
        ),
    )
    parser.add_argument("legacy_profile", nargs="?")
    parser.add_argument("legacy_region", nargs="?")
    parser.add_argument("legacy_instance_type", nargs="?")
    parser.add_argument("legacy_ami", nargs="?")
    parser.add_argument("--profile", dest="profile_option", help="AWS profile")
    parser.add_argument("--region", dest="region_option", help="AWS region")
    parser.add_argument(
        "--instance-type", dest="instance_type_option", help="EC2 instance type"
    )
    parser.add_argument("--ami", dest="ami_option", help="AMI ID")
    parser.add_argument(
        "--yes", action="store_true", help="skip confirmation for migrate-kirocrew"
    )
    parsed = parser.parse_args(normalized)
    if parsed.yes and command != "migrate-kirocrew":
        parser.error("--yes is only valid with migrate-kirocrew")
    return Arguments(
        command=command,
        profile=parsed.profile_option or parsed.legacy_profile,
        region=parsed.region_option or parsed.legacy_region,
        instance_type=parsed.instance_type_option or parsed.legacy_instance_type,
        ami=parsed.ami_option or parsed.legacy_ami,
        assume_yes=parsed.yes,
        browser_app=browser_app,
    )
