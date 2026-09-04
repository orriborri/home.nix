from __future__ import annotations

import json
import os
import shlex
import signal
import socket
import subprocess
import time
from pathlib import Path
from typing import IO, Sequence

from .models import AwsIdentity, LauncherError


def quote_command(command: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def _local_port_in_use(port: int) -> bool:
    """Return True if a listener is actively bound to 127.0.0.1:port.

    Probes with SO_REUSEADDR set, matching how servers (and the SSM plugin)
    bind. This deliberately ignores lingering TIME_WAIT sockets, which do not
    block a fresh listener and drain on their own — treating them as "in use"
    would trigger needless process kills.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return True
    return False


def _listening_pids_for_port(port: int) -> list[int]:
    """Find PIDs holding a listening socket on the given local TCP port.

    Reads /proc/net/tcp{,6} to map the port to socket inodes, then scans
    /proc/<pid>/fd to find the owning processes. Pure stdlib, no external
    commands, so it works even when lsof/ss/fuser are absent.
    """
    target_inodes: set[str] = set()
    for proc_file in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(proc_file, "r", encoding="ascii", errors="replace") as handle:
                next(handle, None)  # skip header
                for line in handle:
                    fields = line.split()
                    if len(fields) < 10:
                        continue
                    local_addr = fields[1]
                    state = fields[3]
                    inode = fields[9]
                    # state 0A == LISTEN
                    if state != "0A":
                        continue
                    _, _, port_hex = local_addr.rpartition(":")
                    try:
                        if int(port_hex, 16) == port:
                            target_inodes.add(inode)
                    except ValueError:
                        continue
        except OSError:
            continue

    if not target_inodes:
        return []

    pids: set[int] = set()
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        fd_dir = os.path.join(entry.path, "fd")
        try:
            fd_names = os.listdir(fd_dir)
        except OSError:
            continue
        for fd_name in fd_names:
            try:
                link = os.readlink(os.path.join(fd_dir, fd_name))
            except OSError:
                continue
            if link.startswith("socket:[") and link[8:-1] in target_inodes:
                pids.add(int(entry.name))
                break
    return sorted(pids)


def _port_forward_plugin_pids(instance_id: str | None = None) -> list[int]:
    """Find session-manager-plugin PIDs running a port-forward session.

    Falls back to /proc/<pid>/cmdline (readable when /proc/<pid>/fd is not,
    e.g. under hidepid or a sandbox). When instance_id is given, only matches
    plugins targeting that instance so unrelated sessions are left alone.
    """
    pids: list[int] = []
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(os.path.join(entry.path, "cmdline"), "rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        cmdline = raw.replace(b"\x00", b" ").decode("utf-8", "replace")
        if "session-manager-plugin" not in cmdline:
            continue
        if "StartSession" not in cmdline and "StartPortForwarding" not in cmdline:
            continue
        if instance_id and instance_id not in cmdline:
            continue
        pids.append(int(entry.name))
    return sorted(pids)


def free_local_port(
    port: int,
    *,
    wait_seconds: float = 3.0,
    instance_id: str | None = None,
) -> list[int]:
    """Kill any process holding a listening socket on 127.0.0.1:port.

    Returns the list of PIDs that were signalled. Sends SIGTERM, then
    SIGKILL if the port does not free within wait_seconds.

    Primary strategy maps the port to owning PIDs via /proc/net/tcp and
    /proc/<pid>/fd. When those file descriptors are not inspectable but the
    port is still bound, falls back to killing session-manager-plugin
    port-forward processes (optionally scoped to instance_id).
    """
    if not _local_port_in_use(port):
        return []

    pids = _listening_pids_for_port(port)
    if not pids:
        pids = _port_forward_plugin_pids(instance_id)
    if not pids:
        return []

    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if not _local_port_in_use(port):
            return pids
        time.sleep(0.1)

    # Still bound: escalate to SIGKILL.
    remaining = _listening_pids_for_port(port) or _port_forward_plugin_pids(instance_id) or pids
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
    time.sleep(0.3)
    return pids


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

    def agent_forward_popen(
        self,
        remote_socket: str,
        local_socket: str,
        user: str = "orre",
    ) -> subprocess.Popen[bytes]:
        """Start a backgrounded ssh session that forwards the local 1Password
        agent socket to a fixed path on the box (as `user`, so the socket is
        owned by that user). Returns the Popen so the caller can terminate it.

        While this session is alive, a relay on the box re-exposes the socket
        to the kirocrew gateway, letting the agent push to git — gated by a
        1Password approval prompt on the local machine. Killing the process
        (e.g. when the portal tunnel closes) revokes that ability.

        Uses `-N` (no remote command) and StreamLocalBindUnlink so a stale
        socket from a previous session is replaced cleanly.
        """
        command = [
            "ssh",
            "-N",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"ProxyCommand={self.proxy_command()}",
            "-i",
            str(self.key_file),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StreamLocalBindUnlink=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-R",
            f"{remote_socket}:{local_socket}",
            f"{user}@{self.instance_id}",
        ]
        return subprocess.Popen(command)

    def portal(self, port: str, local_port: str | None = None) -> None:
        bind_port = int(local_port or port)
        killed = free_local_port(bind_port, instance_id=self.instance_id)
        if killed:
            pid_list = ", ".join(str(pid) for pid in killed)
            print(f"  Freed local port {bind_port} (stopped PID {pid_list}).")
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
