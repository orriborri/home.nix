"""CLI argument parsing for the EC2 launcher."""
from __future__ import annotations

import argparse
from typing import Sequence

from .models import COMMANDS, Arguments, LauncherError


def parse_arguments(argv: Sequence[str]) -> Arguments:
    aliases = {
        "--portal": "portal",
        "--stop": "stop",
        "--destroy": "destroy",
        "--rebuild": "rebuild",
        "--new": "new",
        "--migrate-kirocrew": "migrate-kirocrew",
        "--sync-state": "sync-state",
        "--ssh": "ssh",
    }
    normalized = [aliases.get(argument, argument) for argument in argv]
    selected_commands = [argument for argument in normalized if argument in COMMANDS]
    if len(selected_commands) > 1:
        raise LauncherError("Specify exactly one launcher command")
    command = selected_commands[0] if selected_commands else "start"
    if selected_commands:
        normalized.remove(command)

    parser = argparse.ArgumentParser(
        prog="launch-ec2",
        usage="launch-ec2 [COMMAND] [profile] [region] [instance-type] [ami-id] [OPTIONS]",
        description="Manage the KiroCrew EC2 instance through AWS SSM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "commands:\n"
            "  start              launch or resume and rebuild (default)\n"
            "  portal             start or resume and open http://127.0.0.1:7780\n"
            "  ssh                open interactive shell with X11 forwarding\n"
            "  stop               stop the saved instance\n"
            "  destroy            permanently terminate the saved instance\n"
            "  rebuild            rebuild the saved instance\n"
            "  new                launch a new instance\n"
            "  migrate-kirocrew   migrate local KiroCrew state to the instance\n"
            "  sync-state         sync local kirocrew config, skills, and workspace to remote"
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
    )
