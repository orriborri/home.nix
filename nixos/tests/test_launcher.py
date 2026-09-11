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
