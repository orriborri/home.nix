"""Regression tests for the SSM-only portal/Obsidian launcher flows.

These cover the Step 1 acceptance criteria from repair-plan.md: portal and
Obsidian forwarding, reconnect, the missing Session Manager plugin case,
cancellation, and optional 1Password agent-forward cleanup. They also assert
that no Tailscale code path survives.

The tests drive Launcher methods in isolation. Launcher.__init__ talks to AWS,
so we build a bare instance with object.__new__ and inject only the attributes
the methods under test touch (script_dir plus a fake RemoteHost).
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

MODULE_ROOT = Path(__file__).resolve().parents[1]
if str(MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(MODULE_ROOT))

from kirocrew_ec2 import launcher as launcher_module
from kirocrew_ec2.launcher import Launcher
from kirocrew_ec2.models import (
    OBSIDIAN_PORT,
    PORTAL_LOCAL_PORT,
    PORTAL_PORT,
    LauncherError,
)


class FakeAgentForward:
    """Stand-in for the ssh -R Popen handle returned by _start_agent_forward."""

    def __init__(self, *, alive: bool = True, wait_raises: bool = False) -> None:
        self._alive = alive
        self._wait_raises = wait_raises
        self.terminated = False
        self.killed = False
        self.waited = False

    def poll(self):
        return None if self._alive else 0

    def terminate(self):
        self.terminated = True
        self._alive = False

    def kill(self):
        self.killed = True
        self._alive = False

    def wait(self, timeout=None):
        self.waited = True
        if self._wait_raises:
            raise launcher_module.subprocess.TimeoutExpired(cmd="ssh", timeout=timeout)
        return 0


class FakeRemote:
    """Records the SSM port-forward calls the launcher makes."""

    def __init__(self) -> None:
        self.instance_id = "i-test"
        self.portal_calls: list[tuple[str, str]] = []

    def portal(self, port: str, local_port: str | None = None) -> None:
        self.portal_calls.append((port, local_port))


def make_launcher(remote: FakeRemote) -> Launcher:
    launcher = object.__new__(Launcher)
    launcher.script_dir = MODULE_ROOT
    launcher._remote = lambda state: remote  # type: ignore[assignment]
    return launcher


class TailscaleRemovalTests(unittest.TestCase):
    def test_no_tailscale_symbols_remain(self):
        # The removed helpers/constants must be gone from the modules.
        self.assertFalse(hasattr(Launcher, "_tailscale_reachable"))
        self.assertFalse(hasattr(Launcher, "_port_reachable"))
        from kirocrew_ec2.runtime import RemoteHost

        self.assertFalse(hasattr(RemoteHost, "tailscale_ip"))
        from kirocrew_ec2 import models

        self.assertFalse(hasattr(models, "TTYD_PORT"))

    def test_source_has_no_tailscale_references(self):
        for name in ("launcher.py", "runtime.py", "models.py"):
            text = (MODULE_ROOT / "kirocrew_ec2" / name).read_text()
            self.assertNotIn("tailscale", text.lower(), name)
            self.assertNotIn("ttyd", text.lower(), name)
            self.assertNotIn("7681", text, name)


class PortalFlowTests(unittest.TestCase):
    def setUp(self):
        self.remote = FakeRemote()
        self.launcher = make_launcher(self.remote)

    def test_portal_uses_ssm_forward_and_cleans_up_agent(self):
        agent = FakeAgentForward(alive=True)
        self.launcher._start_agent_forward = lambda remote: agent  # type: ignore
        # Stand in for the blocking reconnect loop: prove the SSM tunnel path
        # runs (never a direct URL), then return as if Ctrl+C ended it.
        forwarded: list[tuple[str, str]] = []
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda remote, rport, lport, *, label: forwarded.append((rport, lport))
        )
        with mock.patch.object(launcher_module.shutil, "which", return_value="/usr/bin/smp"):
            self.launcher._open_portal(state=object())
        self.assertEqual(forwarded, [(PORTAL_PORT, PORTAL_LOCAL_PORT)])
        # Agent forward is torn down when the portal returns.
        self.assertTrue(agent.terminated)
        self.assertTrue(agent.waited)

    def test_portal_without_agent_socket_still_forwards(self):
        self.launcher._start_agent_forward = lambda remote: None  # type: ignore
        forwarded: list[tuple[str, str]] = []
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda remote, rport, lport, *, label: forwarded.append((rport, lport))
        )
        with mock.patch.object(launcher_module.shutil, "which", return_value="/usr/bin/smp"):
            self.launcher._open_portal(state=object())
        self.assertEqual(forwarded, [(PORTAL_PORT, PORTAL_LOCAL_PORT)])

    def test_portal_requires_session_manager_plugin(self):
        agent = FakeAgentForward(alive=True)
        self.launcher._start_agent_forward = lambda remote: agent  # type: ignore
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda *a, **k: (_ for _ in ()).throw(AssertionError("should not forward"))
        )
        with mock.patch.object(launcher_module.shutil, "which", return_value=None), \
             self.assertRaises(LauncherError):
            self.launcher._open_portal(state=object())
        # Even on the early error, the agent forward must be cleaned up.
        self.assertTrue(agent.terminated)

    def test_portal_cleans_up_agent_on_cancellation(self):
        agent = FakeAgentForward(alive=True)
        self.launcher._start_agent_forward = lambda remote: agent  # type: ignore

        def cancel(remote, rport, lport, *, label):
            raise KeyboardInterrupt

        self.launcher._forward_with_reconnect = cancel  # type: ignore
        with mock.patch.object(launcher_module.shutil, "which", return_value="/usr/bin/smp"), \
             self.assertRaises(KeyboardInterrupt):
            self.launcher._open_portal(state=object())
        self.assertTrue(agent.terminated)

    def test_portal_agent_cleanup_kills_on_timeout(self):
        agent = FakeAgentForward(alive=True, wait_raises=True)
        self.launcher._start_agent_forward = lambda remote: agent  # type: ignore
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda remote, rport, lport, *, label: None
        )
        with mock.patch.object(launcher_module.shutil, "which", return_value="/usr/bin/smp"):
            self.launcher._open_portal(state=object())
        self.assertTrue(agent.terminated)
        self.assertTrue(agent.killed)


class ObsidianFlowTests(unittest.TestCase):
    def setUp(self):
        self.remote = FakeRemote()
        self.launcher = make_launcher(self.remote)

    def test_obsidian_uses_ssm_forward_on_local_port(self):
        forwarded: list[tuple[str, str]] = []
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda remote, rport, lport, *, label: forwarded.append((rport, lport))
        )
        opened: list[str] = []
        self.launcher._open_browser = staticmethod(lambda url: opened.append(url))  # type: ignore
        with mock.patch.object(launcher_module.shutil, "which", return_value="/usr/bin/smp"):
            self.launcher._open_obsidian(state=object())
        self.assertEqual(forwarded, [(OBSIDIAN_PORT, OBSIDIAN_PORT)])
        self.assertEqual(opened, [f"https://127.0.0.1:{OBSIDIAN_PORT}/"])

    def test_obsidian_requires_session_manager_plugin(self):
        self.launcher._forward_with_reconnect = (  # type: ignore
            lambda *a, **k: (_ for _ in ()).throw(AssertionError("should not forward"))
        )
        self.launcher._open_browser = staticmethod(lambda url: None)  # type: ignore
        with mock.patch.object(launcher_module.shutil, "which", return_value=None), \
             self.assertRaises(LauncherError):
            self.launcher._open_obsidian(state=object())


class ReconnectLoopTests(unittest.TestCase):
    def setUp(self):
        self.remote = FakeRemote()
        self.launcher = make_launcher(self.remote)

    def test_reconnect_reestablishes_then_stops_on_ctrl_c(self):
        # portal() returns twice (two drops), then Ctrl+C ends the loop.
        calls = {"n": 0}

        def portal(port, local_port=None):
            calls["n"] += 1
            self.remote.portal_calls.append((port, local_port))
            if calls["n"] >= 3:
                raise KeyboardInterrupt

        self.remote.portal = portal  # type: ignore
        # Avoid real backoff sleeps.
        with mock.patch.object(launcher_module.time, "sleep", return_value=None), \
             self.assertRaises(KeyboardInterrupt):
            self.launcher._forward_with_reconnect(
                self.remote, PORTAL_PORT, PORTAL_LOCAL_PORT, label="Portal"
            )
        # Re-established the tunnel on each drop before Ctrl+C stopped it.
        self.assertEqual(len(self.remote.portal_calls), 3)
        self.assertTrue(
            all(call == (PORTAL_PORT, PORTAL_LOCAL_PORT) for call in self.remote.portal_calls)
        )

    def test_reconnect_survives_launcher_error_then_retries(self):
        calls = {"n": 0}

        def portal(port, local_port=None):
            calls["n"] += 1
            if calls["n"] == 1:
                raise LauncherError("transient SSM failure")
            raise KeyboardInterrupt

        self.remote.portal = portal  # type: ignore
        with mock.patch.object(launcher_module.time, "sleep", return_value=None), \
             self.assertRaises(KeyboardInterrupt):
            self.launcher._forward_with_reconnect(
                self.remote, PORTAL_PORT, PORTAL_LOCAL_PORT, label="Portal"
            )
        self.assertEqual(calls["n"], 2)


if __name__ == "__main__":
    unittest.main()


class FakeKeyRemote:
    """Answers `test -s` probes from a set of present paths; records writes."""

    def __init__(self, present: set[str]) -> None:
        self.present = present
        self.writes: list[tuple[str, str]] = []

    def run(self, user, command, capture=False, check=True, input_text=None):
        if command.startswith("test -s "):
            path = command.split()[2]
            out = "yes" if path in self.present else "no"
            return launcher_module.subprocess.CompletedProcess(command, 0, out + "\n", "")
        self.writes.append((command, input_text))
        return launcher_module.subprocess.CompletedProcess(command, 0, "", "")


class AgeKeyBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.launcher = object.__new__(Launcher)
        import tempfile

        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        key = self.tmp / ".config" / "sops" / "age" / "keys.txt"
        key.parent.mkdir(parents=True)
        key.write_text("AGE-SECRET-KEY-TEST\n")
        self.enterContext(mock.patch.object(launcher_module.Path, "home", return_value=self.tmp))
        self.enterContext(mock.patch.object(launcher_module.shutil, "which", return_value=None))

    def test_both_present_writes_nothing(self):
        remote = FakeKeyRemote({path for path, *_ in launcher_module.AGE_KEY_TARGETS})
        self.launcher._bootstrap_age_key(remote)  # type: ignore[arg-type]
        self.assertEqual(remote.writes, [])

    def test_existing_box_gets_root_only_system_key(self):
        # A box bootstrapped before the move has orre's copy only.
        remote = FakeKeyRemote({"/home/orre/.config/sops/age/keys.txt"})
        self.launcher._bootstrap_age_key(remote)  # type: ignore[arg-type]
        self.assertEqual(len(remote.writes), 1)
        command, key = remote.writes[0]
        self.assertIn("install -d -m 700 -o root -g root /var/lib/sops-nix;", command)
        self.assertIn("install -m 400 -o root -g root /dev/stdin /var/lib/sops-nix/key.txt", command)
        self.assertEqual(key, "AGE-SECRET-KEY-TEST\n")

    def test_fresh_box_gets_both_copies(self):
        remote = FakeKeyRemote(set())
        self.launcher._bootstrap_age_key(remote)  # type: ignore[arg-type]
        targets = [command.rsplit(" ", 1)[1] for command, _ in remote.writes]
        self.assertEqual(
            targets,
            ["/home/orre/.config/sops/age/keys.txt", "/var/lib/sops-nix/key.txt"],
        )
        self.assertIn("-o orre -g users", remote.writes[0][0])

    def test_no_key_available_raises(self):
        (self.tmp / ".config" / "sops" / "age" / "keys.txt").unlink()
        with self.assertRaises(launcher_module.LauncherError):
            self.launcher._bootstrap_age_key(FakeKeyRemote(set()))  # type: ignore[arg-type]


class SyncStateTests(unittest.TestCase):
    """sync-state pushes config.json and the workspace, never skills (K2)."""

    def test_skills_are_not_pushed(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as home:
            crew = Path(home) / ".kiro" / "crew"
            (crew / "skills" / "foo").mkdir(parents=True)
            (crew / "skills" / "foo" / "SKILL.md").write_text("---\nname: foo\n---\n")
            (crew / "workspace" / "memory").mkdir(parents=True)

            remote = FakeKeyRemote(present=set())
            launcher = object.__new__(Launcher)
            launcher._remote = lambda state: remote  # type: ignore[assignment]
            sent: list[str] = []
            launcher._send_directory = (  # type: ignore[assignment]
                lambda r, local_path, remote_rel: sent.append(remote_rel)
            )

            with mock.patch.object(Path, "home", return_value=Path(home)), \
                    mock.patch("builtins.print"):
                launcher._sync_state(object())

        self.assertEqual(sent, [".kiro/crew/workspace/memory"])
        self.assertFalse(
            [cmd for cmd, _ in remote.writes if "skills" in cmd],
            "sync-state still talks to the remote skills directory",
        )


class FakeClaudeRemote:
    """Simulates the instance side of `launch-ec2 claude`.

    `logged_in` / `trusted` are the instance state; the interactive login and
    trust sessions set them unless `login_creates` / `trust_accepts` is False.
    The restart script answers "untrusted" until trusted, then "running".
    """

    def __init__(
        self,
        *,
        logged_in: bool,
        trusted: bool = True,
        login_creates: bool = True,
        trust_accepts: bool = True,
        enabled: bool = True,
        crashes: bool = False,
    ) -> None:
        self.logged_in = logged_in
        self.trusted = trusted
        self.login_creates = login_creates
        self.trust_accepts = trust_accepts
        self.enabled = enabled
        self.crashes = crashes
        self.commands: list[str] = []
        self.interactive_calls: list[tuple[str, str]] = []

    @property
    def restarts(self) -> int:
        return sum("systemctl restart claude-remote" in c for c in self.commands)

    def run(self, user, command, capture=False, check=True, input_text=None):
        self.commands.append(command)
        if command.startswith("test -e "):
            code = 0 if self.logged_in else 1
            return launcher_module.subprocess.CompletedProcess(command, code, "", "")
        if "systemctl restart claude-remote" in command:
            if not self.trusted:
                out = "untrusted\n"
            elif not self.enabled:
                out = "enable\n"
            elif self.crashes:
                out = "failed\nMain process exited, code=exited, status=1/FAILURE\n"
            else:
                out = "running\nhttps://claude.ai/code/session_x\n"
            return launcher_module.subprocess.CompletedProcess(command, 0, out, "")
        return launcher_module.subprocess.CompletedProcess(command, 0, "", "")

    def interactive(self, user, command):
        self.interactive_calls.append((user, command))
        if "auth login" in command:
            if self.login_creates:
                self.logged_in = True
        elif "remote-control" in command:
            self.enabled = True
        elif self.trust_accepts:
            self.trusted = True


class ClaudeRemoteFlowTests(unittest.TestCase):
    def _run(self, remote: FakeClaudeRemote) -> None:
        launcher = object.__new__(Launcher)
        launcher._remote = lambda state: remote  # type: ignore[assignment]
        with mock.patch("builtins.print"):
            launcher._open_claude(object())

    def test_logs_in_then_starts_service_when_credentials_missing(self):
        remote = FakeClaudeRemote(logged_in=False)
        self._run(remote)
        self.assertEqual(len(remote.interactive_calls), 1)
        user, command = remote.interactive_calls[0]
        self.assertEqual(user, "root")
        self.assertIn("sudo -u claude-remote -H", command)
        self.assertIn("HTTPS_PROXY=http://127.0.0.1:8888", command)
        self.assertIn("claude auth login", command)
        self.assertEqual(remote.restarts, 1)

    def test_skips_login_when_already_logged_in(self):
        remote = FakeClaudeRemote(logged_in=True)
        self._run(remote)
        self.assertEqual(remote.interactive_calls, [])
        self.assertEqual(remote.restarts, 1)

    def test_failed_login_raises_and_does_not_start_service(self):
        remote = FakeClaudeRemote(logged_in=False, login_creates=False)
        with self.assertRaises(LauncherError):
            self._run(remote)
        self.assertEqual(remote.restarts, 0)

    def test_untrusted_workspace_opens_claude_there_then_restarts(self):
        remote = FakeClaudeRemote(logged_in=True, trusted=False)
        self._run(remote)
        self.assertEqual(len(remote.interactive_calls), 1)
        _, command = remote.interactive_calls[0]
        self.assertIn("cd /var/lib/claude-remote/workspace", command)
        self.assertNotIn("auth login", command)
        self.assertEqual(remote.restarts, 2)

    def test_trust_then_enable_prompts_are_each_answered_once(self):
        remote = FakeClaudeRemote(logged_in=True, trusted=False, enabled=False)
        self._run(remote)
        commands = [c for _, c in remote.interactive_calls]
        self.assertEqual(len(commands), 2)
        self.assertNotIn("remote-control", commands[0])
        self.assertIn("remote-control --name kirocrew", commands[1])
        self.assertIn("cd /var/lib/claude-remote/workspace", commands[1])
        self.assertEqual(remote.restarts, 3)
        stops = [c for c in remote.commands if c == "systemctl stop claude-remote"]
        self.assertEqual(len(stops), 2)

    def test_declined_trust_raises(self):
        remote = FakeClaudeRemote(logged_in=True, trusted=False, trust_accepts=False)
        with self.assertRaises(LauncherError):
            self._run(remote)

    def test_crash_loop_is_reported_not_called_running(self):
        remote = FakeClaudeRemote(logged_in=True, crashes=True)
        with self.assertRaises(LauncherError) as caught:
            self._run(remote)
        self.assertIn("Main process exited", str(caught.exception))


class ClaudeCommandParseTests(unittest.TestCase):
    def test_claude_is_a_command(self):
        from kirocrew_ec2.cli import parse_arguments

        self.assertEqual(parse_arguments(["claude"]).command, "claude")
        self.assertEqual(parse_arguments(["--claude"]).command, "claude")
