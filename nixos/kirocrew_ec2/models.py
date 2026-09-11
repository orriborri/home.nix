from __future__ import annotations

import json
import os
import shlex
import tempfile
from dataclasses import dataclass, field, replace
from datetime import datetime
from pathlib import Path

DEFAULT_REGION = "eu-central-1"
DEFAULT_INSTANCE_TYPE = "t4g.xlarge"
DEFAULT_AMI = "ami-0cdce1c7f7fa96c0d"
KEY_NAME = "kirocrew"
ROLE_NAME = "kirocrew-ssm"
SECURITY_GROUP_NAME = "kirocrew-ssm"
PORTAL_PORT = "5476"
PORTAL_LOCAL_PORT = "7780"
# Xpra HTML5 endpoint for browser Obsidian (kirocrew-obsidian-xpra.nix). The
# service binds 127.0.0.1:14500 on the instance over TLS; `launch-ec2 obsidian`
# forwards it to the same local port and opens the browser.
OBSIDIAN_PORT = "14500"
# Shared code repository tree on the instance. Repos are cloned/pulled here by
# orre and edited by the kirocrew gateway agent; the tree is owned
# orre:code-writers and setgid so both identities can read and write it (see
# kirocrew-code.nix and kirocrew-security.nix).
REMOTE_CODE_DIR = "/var/lib/code"
# Legacy code-tree roots that earlier deploys pinned into the gateway's session
# state (session_map.json, recent_projects.json, and per-session .jsonl project
# headers). After the move to REMOTE_CODE_DIR these paths became stale, and a
# session whose project points at a non-existent read-only path crashes on
# resume. `launch-ec2` rewrites this prefix to REMOTE_CODE_DIR on every deploy
# so the migration is self-healing.
#
# Only /home/orre/code is listed: the move preserved the sub-path
# (/home/orre/code/readpeak/... -> /var/lib/code/readpeak/...), so the rewrite
# is a safe prefix swap. Other historical roots (e.g. /home/orre/Repos) are NOT
# included because their sub-paths do not map cleanly onto the new tree.
LEGACY_CODE_DIRS = (
    "/home/orre/code",
)
# Writable Obsidian vault on the instance, owned by kirocrew (see
# kirocrew-vault.nix). Registered as a gateway project directory so the agent
# can read and write vault notes.
REMOTE_VAULT_DIR = "/var/lib/vault"
# KiroCrew gateway service user's home on headless hosts (see
# kirocrew-services.nix). The gateway reads MCP OAuth tokens from
# REMOTE_MCP_AUTH_DIR under this home.
REMOTE_KIROCREW_HOME = "/var/lib/kirocrew"
REMOTE_MCP_AUTH_DIR = "/var/lib/kirocrew/.mcp-auth/mcp-remote-v1"
# Local mcp-remote OAuth cache. `npx mcp-remote <url>` completes the browser
# flow and writes the cached token here on the workstation.
LOCAL_MCP_AUTH_DIR = "~/.mcp-auth/mcp-remote-v1"
# Remote MCP endpoints reached through mcp-remote. Used by `launch-ec2 auth`.
# Linear removed SSE support; the current endpoint is the streamable HTTP /mcp.
AUTH_SERVER_URLS = {
    "linear": "https://mcp.linear.app/mcp",
    "metabase": "https://metabase.readpeak.com/api/metabase-mcp",
}
# 1Password agent socket bridge. When the portal is open, the launcher forwards
# the operator's local 1Password agent socket to REMOTE_AGENT_SOCKET on the box
# (as orre). A systemd relay there re-exposes it to the kirocrew gateway so the
# agent can push to git — gated by a 1Password approval prompt — ONLY while the
# portal session is alive.
LOCAL_1P_AGENT_SOCKET = "~/.1password/agent.sock"
REMOTE_AGENT_SOCKET = "/run/kirocrew-agent/orre-1p.sock"
GITHUB_ED25519_KEY = (
    "github.com ssh-ed25519 "
    "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
)
GITLAB_ED25519_KEY = (
    "gitlab.com ssh-ed25519 "
    "AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf"
)
COMMANDS = (
    "start",
    "portal",
    "obsidian",
    "connect",
    "stop",
    "destroy",
    "rebuild",
    "new",
    "migrate-kirocrew",
    "sync-state",
    "ssh",
    "auth",
)
AUTH_TARGETS = ("linear", "metabase")
CONFIG_KEYS = {
    "DEFAULT_PROFILE",
    "DEFAULT_REGION",
    "DEFAULT_INSTANCE_TYPE",
    "DEFAULT_AMI",
}


class LauncherError(RuntimeError):
    """A user-facing launcher error."""


@dataclass(frozen=True)
class Arguments:
    command: str
    profile: str | None
    region: str | None
    instance_type: str | None
    ami: str | None
    assume_yes: bool
    auth_target: str | None = None
    force: bool = False


@dataclass(frozen=True)
class AwsIdentity:
    account_id: str
    arn: str

    @property
    def partition(self) -> str:
        parts = self.arn.split(":", maxsplit=2)
        return parts[1] if len(parts) > 1 else "aws"


@dataclass(frozen=True)
class PreviousInstance:
    instance_id: str
    region: str
    profile: str
    account_id: str = ""

    @classmethod
    def from_json(cls, data: object) -> PreviousInstance:
        if not isinstance(data, dict):
            raise LauncherError("previous instance must be a JSON object")
        return cls(
            instance_id=require_string(data, "instance_id"),
            region=require_string(data, "region"),
            profile=optional_string(data, "profile"),
            account_id=optional_string(data, "account_id"),
        )

    def to_json(self) -> dict[str, str]:
        return {
            "instance_id": self.instance_id,
            "region": self.region,
            "profile": self.profile,
            "account_id": self.account_id,
        }


@dataclass(frozen=True)
class InstanceState:
    instance_id: str
    region: str
    profile: str = ""
    account_id: str = ""
    caller_arn: str = ""
    lifecycle: str = "running"
    client_token: str = ""
    security_group_id: str = ""
    key_pair_id: str = ""
    key_fingerprint: str = ""
    ami: str = ""
    instance_type: str = ""
    key_file: str = ""
    flake_dir: str = ""
    created: str = ""
    previous_instances: tuple[PreviousInstance, ...] = field(default_factory=tuple)

    @classmethod
    def from_json(cls, raw: object) -> InstanceState:
        if not isinstance(raw, dict):
            raise LauncherError("expected a JSON object")
        previous_raw = raw.get("previous_instances", [])
        if not isinstance(previous_raw, list):
            raise LauncherError("previous_instances must be a JSON array")
        return cls(
            instance_id=optional_string(raw, "instance_id"),
            region=require_string(raw, "region"),
            profile=optional_string(raw, "profile"),
            account_id=optional_string(raw, "account_id"),
            caller_arn=optional_string(raw, "caller_arn"),
            lifecycle=optional_string(raw, "lifecycle") or "running",
            client_token=optional_string(raw, "client_token"),
            security_group_id=optional_string(raw, "security_group_id"),
            key_pair_id=optional_string(raw, "key_pair_id"),
            key_fingerprint=optional_string(raw, "key_fingerprint"),
            ami=optional_string(raw, "ami"),
            instance_type=optional_string(raw, "instance_type"),
            key_file=optional_string(raw, "key_file"),
            flake_dir=optional_string(raw, "flake_dir"),
            created=optional_string(raw, "created"),
            previous_instances=tuple(
                PreviousInstance.from_json(item) for item in previous_raw
            ),
        )

    def to_json(self) -> dict[str, object]:
        return {
            "instance_id": self.instance_id,
            "region": self.region,
            "profile": self.profile,
            "account_id": self.account_id,
            "caller_arn": self.caller_arn,
            "lifecycle": self.lifecycle,
            "client_token": self.client_token,
            "security_group_id": self.security_group_id,
            "key_pair_id": self.key_pair_id,
            "key_fingerprint": self.key_fingerprint,
            "ami": self.ami,
            "instance_type": self.instance_type,
            "key_file": self.key_file,
            "flake_dir": self.flake_dir,
            "created": self.created,
            "previous_instances": [item.to_json() for item in self.previous_instances],
        }

    def updated(self, **changes: object) -> InstanceState:
        return replace(self, **changes)

    def as_previous(self) -> PreviousInstance | None:
        if not self.instance_id:
            return None
        return PreviousInstance(
            instance_id=self.instance_id,
            region=self.region,
            profile=self.profile,
            account_id=self.account_id,
        )


class StateStore:
    """Atomically persists ownership of the active and replaced EC2 instances."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> InstanceState | None:
        if not self.path.exists():
            return None
        try:
            return InstanceState.from_json(json.loads(self.path.read_text()))
        except (OSError, json.JSONDecodeError, TypeError, LauncherError) as error:
            raise LauncherError(f"Invalid state file {self.path}: {error}") from error

    def load_for_replacement(self) -> InstanceState | None:
        try:
            return self.load()
        except LauncherError:
            self._archive_invalid()
            return None

    def save(self, state: InstanceState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.", dir=self.path.parent
        )
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(state.to_json(), stream, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def clear(self) -> None:
        self.path.unlink(missing_ok=True)

    def _archive_invalid(self) -> None:
        timestamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
        archive = self.path.with_name(f"{self.path.name}.invalid-{timestamp}")
        os.replace(self.path, archive)


def require_string(data: dict[str, object], key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise LauncherError(f"missing non-empty string field {key!r}")
    return value


def optional_string(data: dict[str, object], key: str) -> str:
    value = data.get(key, "")
    if not isinstance(value, str):
        raise LauncherError(f"field {key!r} must be a string")
    return value


def parse_config(path: Path) -> dict[str, str]:
    """Parse the launcher's simple KEY=VALUE config without executing shell code."""
    if not path.exists():
        return {}

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, raw_value = line.partition("=")
        key = key.strip()
        if not separator or key not in CONFIG_KEYS:
            raise LauncherError(f"Unsupported config entry at {path}:{line_number}")
        try:
            parsed = shlex.split(raw_value, comments=True, posix=True)
        except ValueError as error:
            raise LauncherError(f"Invalid config value at {path}:{line_number}: {error}") from error
        if len(parsed) != 1:
            raise LauncherError(f"Config value at {path}:{line_number} must contain one value")
        values[key] = parsed[0]
    return values
