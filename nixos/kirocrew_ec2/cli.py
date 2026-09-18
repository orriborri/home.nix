"""CLI argument parsing for the EC2 launcher."""
from __future__ import annotations

import argparse
from typing import Sequence

from .models import AUTH_TARGETS, COMMANDS, Arguments, LauncherError


def parse_arguments(argv: Sequence[str]) -> Arguments:
    aliases = {
        "--portal": "portal",
        "--obsidian": "obsidian",
        "--stop": "stop",
        "--destroy": "destroy",
        "--rebuild": "rebuild",
        "--resize": "resize",
        "--new": "new",
        "--migrate-kirocrew": "migrate-kirocrew",
        "--sync-state": "sync-state",
        "--ssh": "ssh",
        "--connect": "connect",
        "--token": "token",
    }
    normalized = [aliases.get(argument, argument) for argument in argv]
    selected_commands = [argument for argument in normalized if argument in COMMANDS]
    if len(selected_commands) > 1:
        raise LauncherError("Specify exactly one launcher command")
    command = selected_commands[0] if selected_commands else "start"
    if selected_commands:
        normalized.remove(command)

    auth_target: str | None = None
    if command == "auth":
        targets = [argument for argument in normalized if argument in AUTH_TARGETS]
        if len(targets) > 1:
            raise LauncherError(
                "auth takes at most one target "
                f"({', '.join(AUTH_TARGETS)}); pass none to do all of them"
            )
        # No target means every target. Authorising one at a time was busywork:
        # the flow is idempotent per target (a token that already probes valid
        # is left alone), so doing all of them is the useful default.
        auth_target = targets[0] if targets else None
        if auth_target:
            normalized.remove(auth_target)

    # `resize` takes the target instance type as a bare positional
    # (`resize t4g.2xlarge`). Pull it out here so the generic positional parse
    # below doesn't mistake it for the profile slot. `--instance-type` still
    # works too and takes precedence; a legacy positional is the final fallback.
    resize_type: str | None = None
    if command == "resize":
        # An EC2 instance type looks like "<family><size>.<class>" e.g.
        # t4g.2xlarge, m7g.large, c7g.xlarge — a token containing a dot and no
        # slash, not an option flag. Match the first such BARE positional, but
        # never consume the value that belongs to --instance-type (that stays
        # for argparse to bind).
        for index, argument in enumerate(normalized):
            preceded_by_opt = index > 0 and normalized[index - 1] in {
                "--instance-type",
                "--profile",
                "--region",
                "--ami",
            }
            if (
                "." in argument
                and not argument.startswith("-")
                and "/" not in argument
                and not preceded_by_opt
            ):
                resize_type = argument
                normalized.pop(index)
                break

    parser = argparse.ArgumentParser(
        prog="launch-ec2",
        usage="launch-ec2 [COMMAND] [profile] [region] [instance-type] [ami-id] [OPTIONS]",
        description="Manage the KiroCrew EC2 instance through AWS SSM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "commands:\n"
            "  start              launch or resume and rebuild (default)\n"
            "  portal             start or resume and open http://127.0.0.1:7780\n"
            "  obsidian           start or resume and open Obsidian at https://127.0.0.1:14500\n"
            "  connect            open a direct SSM session to the instance\n"
            "  ssh                open interactive shell with X11 forwarding\n"
            "  token              print a KiroCrew dashboard access URL (with auth token)\n"
            "  stop               stop the saved instance\n"
            "  destroy            permanently terminate the saved instance\n"
            "  rebuild            rebuild the saved instance\n"
            "  resize TYPE        stop, change instance type, and restart\n"
            "                     (e.g. resize t4g.2xlarge). Preserves the disk\n"
            "                     and all state; the instance briefly goes down.\n"
            "  new                launch a new instance\n"
            "  migrate-kirocrew   migrate local KiroCrew state to the instance\n"
            "  sync-state         sync local kirocrew config, skills, and workspace to remote\n"
            "  auth [target]      run MCP OAuth locally and install the token on the gateway\n"
            "                     (no target = all of them; targets: linear, metabase)"
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
    parser.add_argument(
        "--force",
        action="store_true",
        help="auth: clear the cached token first to force a fresh browser login",
    )
    parsed = parser.parse_args(normalized)
    if parsed.yes and command != "migrate-kirocrew":
        parser.error("--yes is only valid with migrate-kirocrew")
    if parsed.force and command != "auth":
        parser.error("--force is only valid with auth")
    resolved_instance_type = (
        parsed.instance_type_option or resize_type or parsed.legacy_instance_type
    )
    if command == "resize" and not resolved_instance_type:
        parser.error(
            "resize requires a target instance type, e.g. "
            "'launch-ec2 resize t4g.2xlarge'"
        )
    return Arguments(
        command=command,
        profile=parsed.profile_option or parsed.legacy_profile,
        region=parsed.region_option or parsed.legacy_region,
        instance_type=resolved_instance_type,
        ami=parsed.ami_option or parsed.legacy_ami,
        assume_yes=parsed.yes,
        auth_target=auth_target,
        force=parsed.force,
    )
