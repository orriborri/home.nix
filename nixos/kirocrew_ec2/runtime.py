from __future__ import annotations

import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import IO, Sequence

from .models import AwsIdentity, LauncherError


def quote_command(command: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


class CommandRunner:
    """Runs local commands without a shell and normalizes user-facing failures."""

    def run(
        self,
        command: Sequence[str],
        *,
        capture: bool = False,
        check: bool = True,
        env: dict[str, str] | None = None,
        input_text: str | None = None,
        stdin: IO[bytes] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        kwargs: dict[str, object] = {"check": check, "env": env}
        if capture:
            kwargs.update(capture_output=True, text=True)
        elif input_text is not None:
            kwargs.update(input=input_text, text=True)
        elif stdin is not None:
            kwargs["stdin"] = stdin
        return subprocess.run(list(command), **kwargs)  # type: ignore[arg-type]

    def run_bytes(
        self,
        command: Sequence[str],
        *,
        check: bool = True,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(list(command), check=check, capture_output=True)


class AwsCli:
    """Owns AWS CLI identity, region, and error classification."""

    def __init__(self, runner: CommandRunner, profile: str, region: str) -> None:
        self.runner = runner
        self.profile = profile
        self.region = region

    def command(self, *arguments: str) -> list[str]:
        return ["aws", "--profile", self.profile, "--region", self.region, *arguments]

    def global_command(self, *arguments: str) -> list[str]:
        return ["aws", "--profile", self.profile, *arguments]

    def run(
        self,
        *arguments: str,
        capture: bool = False,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self.runner.run(
            self.command(*arguments), capture=capture, check=check
        )

    def run_global(
        self,
        *arguments: str,
        capture: bool = False,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self.runner.run(
            self.global_command(*arguments), capture=capture, check=check
        )

    def text(self, *arguments: str) -> str:
        return self.run(*arguments, capture=True).stdout.strip()

    def json(self, *arguments: str) -> object:
        output = self.text(*arguments, "--output", "json")
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise LauncherError(
                f"AWS returned invalid JSON for {quote_command(arguments)}"
            ) from error

    def identity(self) -> AwsIdentity:
        result = self.run(
            "sts", "get-caller-identity", "--output", "json", capture=True, check=False
        )
        if result.returncode != 0:
            raise LauncherError(
                f"AWS credentials for profile {self.profile!r} are invalid; "
                f"run: aws sso login --profile {self.profile}"
            )
        try:
            data = json.loads(result.stdout)
            account_id = data["Account"]
            arn = data["Arn"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise LauncherError("AWS STS returned an invalid caller identity") from error
        if not isinstance(account_id, str) or not isinstance(arn, str):
            raise LauncherError("AWS STS caller identity fields must be strings")
        return AwsIdentity(account_id=account_id, arn=arn)

    @staticmethod
    def is_missing(result: subprocess.CompletedProcess[str], code: str) -> bool:
        return result.returncode != 0 and code in (result.stderr or "")

    @staticmethod
    def require_success(
        result: subprocess.CompletedProcess[str], operation: str
    ) -> None:
        if result.returncode == 0:
            return
        detail = (result.stderr or "").strip() or "unknown AWS error"
        raise LauncherError(f"{operation} failed: {detail}")


class RemoteHost:
    """Owns SSH-over-SSM transport to one managed EC2 instance."""

    def __init__(
        self,
        runner: CommandRunner,
        aws: AwsCli,
        instance_id: str,
        key_file: Path,
    ) -> None:
        self.runner = runner
        self.aws = aws
        self.instance_id = instance_id
        self.key_file = key_file

    def proxy_command(self) -> str:
        return quote_command(
            [
                "aws",
                "ssm",
                "start-session",
                "--profile",
                self.aws.profile,
                "--region",
                self.aws.region,
                "--target",
                self.instance_id,
                "--document-name",
                "AWS-StartSSHSession",
                "--parameters",
                "portNumber=22",
            ]
        )

    def run(
        self,
        user: str,
        remote_command: str,
        *,
        capture: bool = False,
        check: bool = True,
        input_text: str | None = None,
        stdin: IO[bytes] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            "ssh",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"ProxyCommand={self.proxy_command()}",
            "-i",
            str(self.key_file),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            f"{user}@{self.instance_id}",
            remote_command,
        ]
        return self.runner.run(
            command,
            capture=capture,
            check=check,
            input_text=input_text,
            stdin=stdin,
        )

    def nix_ssh_options(self) -> str:
        return (
            f"-i {shlex.quote(str(self.key_file))} -o IdentitiesOnly=yes "
            "-o StrictHostKeyChecking=accept-new "
            f"-o ProxyCommand={shlex.quote(self.proxy_command())}"
        )

    def portal(self, port: str, local_port: str | None = None) -> None:
        self.aws.run(
            "ssm",
            "start-session",
            "--target",
            self.instance_id,
            "--document-name",
            "AWS-StartPortForwardingSession",
            "--parameters",
            json.dumps(
                {"portNumber": [port], "localPortNumber": [local_port or port]},
                separators=(",", ":"),
            ),
        )

    def tailscale_ip(self) -> str | None:
        """Return the remote instance's Tailscale IPv4 address, or None."""
        result = self.run(
            "root",
            "tailscale ip -4 2>/dev/null || true",
            capture=True,
            check=False,
        )
        ip = result.stdout.strip() if result.returncode == 0 else ""
        return ip if ip and not ip.startswith("error") else None

    def x11_ssh(self, user: str) -> None:
        """Open an interactive SSH session with X11 forwarding.

        Drops into a login shell with DISPLAY set. Run GUI apps from there.
        Blocks until the user exits the shell.
        """
        command = [
            "ssh",
            "-Y",
            "-C",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"ProxyCommand={self.proxy_command()}",
            "-i", str(self.key_file),
            "-o", "IdentitiesOnly=yes",
            f"{user}@{self.instance_id}",
        ]
        subprocess.run(command)


def inherited_environment(**updates: str) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(updates)
    return environment
