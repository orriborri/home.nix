"""Main coordinator that ties AWS resources, state, and remote host together."""
from __future__ import annotations

import base64
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid
from datetime import datetime
from pathlib import Path

from .aws_resources import AwsResources
from .token_probe import classify
from .models import (
    DEFAULT_AMI,
    DEFAULT_INSTANCE_TYPE,
    DEFAULT_REGION,
    AUTH_SERVER_URLS,
    AUTH_TARGETS,
    AUTH_MIN_REMAINING_SECS,
    KEY_NAME,
    LEGACY_CODE_DIRS,
    LOCAL_1P_AGENT_SOCKET,
    LOCAL_MCP_AUTH_DIR,
    OBSIDIAN_PORT,
    PORTAL_LOCAL_PORT,
    PORTAL_PORT,
    REMOTE_AGENT_SOCKET,
    REMOTE_CODE_DIR,
    REMOTE_KIROCREW_BIN,
    REMOTE_KIROCREW_HOME,
    REMOTE_MCP_AUTH_DIR,
    REMOTE_VAULT_DIR,
    Arguments,
    InstanceState,
    LauncherError,
    PreviousInstance,
    StateStore,
    parse_config,
)
from .runtime import AwsCli, CommandRunner, RemoteHost, inherited_environment


class Launcher:
    """Coordinates user commands across state, AWS resources, and the remote host."""

    def __init__(self, arguments: Arguments, script_dir: Path) -> None:
        self.arguments = arguments
        self.script_dir = script_dir
        self.flake_dir = script_dir.parent
        self.config_file = script_dir / ".kirocrew-ec2.config"
        self.store = StateStore(script_dir / ".kirocrew-ec2.json")
        self.defaults = parse_config(self.config_file)
        self.saved_state = (
            self.store.load_for_replacement()
            if arguments.command == "new"
            else self.store.load()
        )

        use_saved = arguments.command != "new" and self.saved_state is not None
        saved_profile = self.saved_state.profile if self.saved_state else ""
        saved_region = self.saved_state.region if use_saved else ""
        profile = (
            arguments.profile
            or saved_profile
            or self.defaults.get("DEFAULT_PROFILE", "")
        )
        region = (
            arguments.region
            or saved_region
            or self.defaults.get("DEFAULT_REGION", DEFAULT_REGION)
        )
        if not profile:
            raise LauncherError(
                f"No AWS profile specified, saved in {self.store.path}, "
                f"or configured in {self.config_file}"
            )

        self.instance_type = arguments.instance_type or self.defaults.get(
            "DEFAULT_INSTANCE_TYPE", DEFAULT_INSTANCE_TYPE
        )
        self.ami = arguments.ami or self.defaults.get("DEFAULT_AMI", DEFAULT_AMI)
        self.key_file = Path.home() / ".ssh" / f"{KEY_NAME}.pem"
        self.runner = CommandRunner()
        self.aws = AwsCli(self.runner, profile, region)
        self.identity = self.aws.identity()
        self.resources = AwsResources(
            self.runner, self.aws, self.store, self.identity, self.key_file
        )

    # ── Public command dispatch ────────────────────────────────────────────────

    def run(self) -> None:
        print(
            f"» AWS identity: {self.identity.account_id} "
            f"({self.aws.profile}, {self.aws.region})"
        )
        if self.arguments.command == "stop":
            self._stop()
            return
        if self.arguments.command == "destroy":
            self._destroy()
            return
        if self.arguments.command == "resize":
            self._resize()
            return

        if self.saved_state is not None:
            self.saved_state = self.resources.bind_identity(self.saved_state)

        if self.arguments.command == "new":
            state = self._launch_replacement()
        else:
            state = self._ensure_active()
            if state is None:
                if self.arguments.command != "start":
                    raise LauncherError(
                        f"{self.arguments.command} requires a managed instance"
                    )
                state = self._launch_replacement()

        if self.arguments.command == "portal":
            self._open_portal(state)
            return
        if self.arguments.command == "obsidian":
            self._open_obsidian(state)
            return
        if self.arguments.command == "connect":
            self._open_ssm_session(state)
            return
        if self.arguments.command == "token":
            self._print_token(state)
            return
        if self.arguments.command == "ssh":
            self._open_ssh(state)
            return
        if self.arguments.command == "migrate-kirocrew":
            self._migrate(state)
            return
        if self.arguments.command == "sync-state":
            self._sync_state(state)
            return
        if self.arguments.command == "auth":
            self._auth(state)
            return
        self._deploy(state)

    # ── Lifecycle helpers ──────────────────────────────────────────────────────

    def _ensure_active(self) -> InstanceState | None:
        state = self.saved_state
        if state is None:
            return None
        if state.lifecycle in {"launching", "provisioning"}:
            state = self.resources.recover_or_launch(state)
            state = self.resources.finish_launch(state)
            self.resources.wait_for_ssm(state.instance_id)
            self.saved_state = state
            return state
        if not state.instance_id:
            raise LauncherError("State has no instance ID or pending token")

        current = self.resources.instance_state(state.instance_id)
        if current == "running":
            self.resources.wait_for_ssm(state.instance_id)
            return self._persist(state, "running")
        if current in {"stopped", "stopping"}:
            if current == "stopping":
                self.aws.run(
                    "ec2", "wait", "instance-stopped",
                    "--instance-ids", state.instance_id
                )
            print(f"» Starting stopped instance {state.instance_id}...")
            self.aws.run(
                "ec2", "start-instances", "--instance-ids", state.instance_id
            )
            self.aws.run(
                "ec2", "wait", "instance-running",
                "--instance-ids", state.instance_id
            )
            state = self._persist(state, "running")
            self.resources.wait_for_ssm(state.instance_id)
            return state
        if current in {"terminated", "shutting-down", "not-found"}:
            previous = state.as_previous()
            updated = state.updated(
                instance_id="",
                lifecycle="terminated",
                previous_instances=_append_previous(
                    state.previous_instances, previous
                ),
            )
            self.store.save(updated)
            self.saved_state = updated
            return None
        raise LauncherError(
            f"Instance {state.instance_id} is {current}; ownership retained"
        )

    def _launch_replacement(self) -> InstanceState:
        previous_state = self.saved_state
        self.resources.ensure_iam()
        key_pair_id, key_fingerprint = self.resources.ensure_key_pair()
        security_group_id = self.resources.ensure_security_group()
        previous = previous_state.as_previous() if previous_state else None
        previous_instances = _append_previous(
            previous_state.previous_instances if previous_state else (), previous
        )
        token = str(uuid.uuid4())
        state = InstanceState(
            instance_id="",
            region=self.aws.region,
            profile=self.aws.profile,
            account_id=self.identity.account_id,
            caller_arn=self.identity.arn,
            lifecycle="launching",
            client_token=token,
            security_group_id=security_group_id,
            key_pair_id=key_pair_id,
            key_fingerprint=key_fingerprint,
            ami=self.ami,
            instance_type=self.instance_type,
            key_file=str(self.key_file),
            flake_dir=str(self.flake_dir),
            created=datetime.now().astimezone().isoformat(timespec="seconds"),
            previous_instances=previous_instances,
        )
        self.store.save(state)
        print(f"» Launching {self.instance_type} from {self.ami}...")
        state = self.resources.recover_or_launch(state)
        print(f"  Instance: {state.instance_id}")
        state = self.resources.finish_launch(state)
        self.resources.wait_for_ssm(state.instance_id)
        self.saved_state = state
        if previous:
            print(f"  Previous instance {previous.instance_id} retained in state history")
        return state

    def _stop(self) -> None:
        state = self._require_bound_state()
        current = self.resources.instance_state(state.instance_id)
        if current == "stopped":
            print(f"Instance {state.instance_id} is already stopped.")
            return
        self._persist(state, "stopping")
        self.aws.run("ec2", "stop-instances", "--instance-ids", state.instance_id)
        print("  ✓ Stop initiated; ownership retained")

    def _resize(self) -> None:
        """Change the EC2 instance type in place: stop, modify, start.

        A running EC2 instance's type is immutable; AWS only allows the change
        while the instance is stopped. This does the full cycle and restarts the
        box, so the root/EBS volume and ALL state (the built source release, the
        vault, MCP tokens, config) are preserved — only the compute shape
        changes. The instance is briefly DOWN during the stop/start, which
        interrupts any in-flight agent sessions, the same as `stop` + `start`.

        The new type is persisted to the saved state so a later `start`/`rebuild`
        relaunch (which reads `instance_type` from state) keeps the new shape
        rather than reverting to the packaged default. The user-level
        DEFAULT_INSTANCE_TYPE in .kirocrew-ec2.config is NOT rewritten here (it is
        an operator-owned file); this prints a reminder when the two disagree.
        """
        state = self._require_bound_state()
        target = self.instance_type
        if not target:
            raise LauncherError("resize requires a target instance type")

        current = self.resources.instance_state(state.instance_id)
        if current in {"terminated", "shutting-down", "not-found"}:
            raise LauncherError(
                f"Instance {state.instance_id} is {current}; cannot resize"
            )

        # The saved type may be blank on older state; only skip when we can
        # positively confirm the live instance already runs the target type.
        live_type = self._live_instance_type(state.instance_id)
        if live_type == target and current == "running":
            print(f"Instance {state.instance_id} is already {target}; nothing to do.")
            if state.instance_type != target:
                self._persist_type(state, target, "running")
            return

        print(
            f"» Resizing {state.instance_id}: "
            f"{live_type or state.instance_type or 'unknown'} → {target}"
        )

        # 1. Stop (idempotent: skip if already stopped).
        if current != "stopped":
            print("  Stopping instance...")
            self._persist(state, "stopping")
            self.aws.run("ec2", "stop-instances", "--instance-ids", state.instance_id)
            self.aws.run(
                "ec2", "wait", "instance-stopped", "--instance-ids", state.instance_id
            )
            print("  ✓ Stopped")

        # 2. Modify the immutable-while-running instance type.
        print(f"  Setting instance type to {target}...")
        self.aws.run(
            "ec2",
            "modify-instance-attribute",
            "--instance-id",
            state.instance_id,
            "--instance-type",
            f"Value={target}",
        )
        # Persist the new type NOW, before the start: if the start races or the
        # process dies, the saved state already reflects the type the instance
        # actually carries, so a later `start` cannot relaunch the old shape.
        state = self._persist_type(state, target, "starting")

        # 3. Start and wait for the SSM agent to come back.
        print("  Starting instance...")
        self.aws.run("ec2", "start-instances", "--instance-ids", state.instance_id)
        self.aws.run(
            "ec2", "wait", "instance-running", "--instance-ids", state.instance_id
        )
        self.resources.wait_for_ssm(state.instance_id)
        state = self._persist(state, "running")
        print(f"  ✓ Instance is running as {target}")

        # Nudge the operator to keep the packaged default in step, since state
        # (this JSON) and the .config default are separate sources.
        config_default = self.defaults.get("DEFAULT_INSTANCE_TYPE")
        if config_default and config_default != target:
            print(
                f"  Note: DEFAULT_INSTANCE_TYPE in {self.config_file} is still "
                f"{config_default!r}. Update it to {target!r} to make this the "
                "default for future launches."
            )

    def _live_instance_type(self, instance_id: str) -> str:
        """The instance type AWS currently reports, or '' if unreadable."""
        result = self.aws.run(
            "ec2",
            "describe-instances",
            "--instance-ids",
            instance_id,
            "--query",
            "Reservations[0].Instances[0].InstanceType",
            "--output",
            "text",
            capture=True,
            check=False,
        )
        value = (result.stdout or "").strip()
        return "" if not value or value == "None" else value

    def _persist_type(
        self, state: InstanceState, instance_type: str, lifecycle: str
    ) -> InstanceState:
        updated = state.updated(instance_type=instance_type, lifecycle=lifecycle)
        self.store.save(updated)
        self.saved_state = updated
        return updated

    def _destroy(self) -> None:
        state = self._require_bound_state()
        print(f"DESTROY {state.instance_id} in {state.region}.")
        if input("Type 'destroy' to confirm: ").strip() != "destroy":
            print("Aborted.")
            return
        self._persist(state, "terminating")
        self.aws.run(
            "ec2", "terminate-instances", "--instance-ids", state.instance_id
        )
        self.aws.run(
            "ec2", "wait", "instance-terminated", "--instance-ids", state.instance_id
        )
        self.store.clear()
        self.saved_state = None
        print("  ✓ Instance terminated and state removed")

    def _open_portal(self, state: InstanceState) -> None:
        remote = self._remote(state)
        # Start the 1Password agent socket forward for the duration of the
        # portal session. While the portal is open the kirocrew gateway can
        # push to git using the operator's forwarded agent (with a 1Password
        # approval prompt); closing the portal revokes it. Best-effort: if the
        # local agent socket is absent, skip the forward rather than fail the
        # portal.
        agent_forward = self._start_agent_forward(remote)
        try:
            # Access is SSM-only: hold an SSM port-forward open (with reconnect)
            # and open the local URL. There is no direct/VPN path.
            if shutil.which("session-manager-plugin") is None:
                raise LauncherError("The AWS Session Manager plugin is required")
            print(f"\n» Opening KiroCrew portal at http://127.0.0.1:{PORTAL_LOCAL_PORT}")
            if agent_forward is not None:
                print("  Agent git-push enabled while the portal is open (1Password will prompt).")
            print("  Keep this command running; press Ctrl+C to close the tunnel.")
            self._run_portal_with_reconnect(remote)
        finally:
            if agent_forward is not None and agent_forward.poll() is None:
                agent_forward.terminate()
                try:
                    agent_forward.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    agent_forward.kill()
                print("  Agent git-push forward closed.")

    def _run_portal_with_reconnect(self, remote: "RemoteHost") -> None:
        """Hold the SSM port-forward open, reconnecting when it drops.

        The SSM session ends whenever the network blips, the instance restarts
        its agent, or AWS times the session out. Each of those returns from
        remote.portal(); we back off briefly and re-establish the tunnel so the
        local portal URL keeps working. Only Ctrl+C ends the loop.
        """
        self._forward_with_reconnect(
            remote, PORTAL_PORT, PORTAL_LOCAL_PORT, label="Portal"
        )

    def _forward_with_reconnect(
        self,
        remote: "RemoteHost",
        remote_port: str,
        local_port: str,
        *,
        label: str,
    ) -> None:
        """Hold an SSM port-forward open, reconnecting when it drops.

        Shared by the portal and Obsidian tunnels. The SSM session ends on any
        network blip, agent restart, or AWS timeout; each returns from
        remote.portal(), so we back off briefly and re-establish it. Only
        Ctrl+C ends the loop.
        """
        backoff = 2
        max_backoff = 30
        while True:
            started = time.monotonic()
            try:
                remote.portal(remote_port, local_port)
            except KeyboardInterrupt:
                raise
            except LauncherError as error:
                print(f"  ⚠ Port-forward error: {error}")
            # A session that ran for a while was healthy; reset the backoff so a
            # long-lived tunnel that finally drops reconnects immediately.
            if time.monotonic() - started >= 15:
                backoff = 2
            try:
                print(
                    f"  {label} disconnected; reconnecting in {backoff}s "
                    "(Ctrl+C to stop)..."
                )
                time.sleep(backoff)
            except KeyboardInterrupt:
                raise
            backoff = min(backoff * 2, max_backoff)

    def _open_obsidian(self, state: InstanceState) -> None:
        """Open browser Obsidian (Xpra HTML5) through an SSM port-forward.

        Access is SSM-only: hold an SSM tunnel open (with reconnect) and open
        the local URL. The Xpra endpoint is TLS with a self-signed certificate,
        so the browser will warn on first connect — expected for a
        loopback/tunnelled service. The session persists on the instance;
        closing this tunnel only ends local access, not the running Obsidian
        process.
        """
        remote = self._remote(state)
        url_path = "/"
        if shutil.which("session-manager-plugin") is None:
            raise LauncherError("The AWS Session Manager plugin is required")
        url = f"https://127.0.0.1:{OBSIDIAN_PORT}{url_path}"
        print(f"\n» Opening Obsidian at {url}")
        print("  TLS uses a self-signed cert; accept the browser warning.")
        print("  Keep this command running; press Ctrl+C to close the tunnel.")
        # Open the browser shortly; the tunnel loop below blocks. The page
        # retries until the forward is established, so a small head start is
        # fine and avoids needing a second process.
        self._open_browser(url)
        self._forward_with_reconnect(
            remote, OBSIDIAN_PORT, OBSIDIAN_PORT, label="Obsidian"
        )

    def _start_agent_forward(self, remote: "RemoteHost"):
        """Start the 1Password agent socket forward if the local socket exists.

        Returns the Popen handle, or None if the local 1Password agent socket
        is not present (in which case agent git-push is simply unavailable).
        """
        local_socket = os.path.expanduser(LOCAL_1P_AGENT_SOCKET)
        if not os.path.exists(local_socket):
            print(
                "  ⚠ 1Password agent socket not found locally "
                f"({LOCAL_1P_AGENT_SOCKET}); agent git-push disabled this session."
            )
            return None
        return remote.agent_forward_popen(
            REMOTE_AGENT_SOCKET, local_socket, user="orre"
        )

    def _open_ssh(self, state: InstanceState) -> None:
        remote = self._remote(state)
        print("\n» Opening interactive shell with X11 forwarding...")
        print("  Run 'firefox &' or 'chromium &' to launch browsers.")
        remote.x11_ssh("orre")

    def _open_ssm_session(self, state: InstanceState) -> None:
        if not state.instance_id:
            raise LauncherError("Cannot connect without an instance ID")
        if shutil.which("session-manager-plugin") is None:
            raise LauncherError("The AWS Session Manager plugin is required")
        print(f"\n» Opening SSM session to {state.instance_id}...")
        self.aws.run(
            "ssm", "start-session", "--target", state.instance_id,
        )

    def _print_token(self, state: InstanceState) -> None:
        """Print a KiroCrew dashboard access URL minted on the instance.

        The dashboard token is a KiroCrew application feature: the gateway
        signs it with its own token_signing.key and validates the signature,
        independent of the SSM tunnel. `kirocrew token` prints
        ``http://localhost:<port>?token=<jwt>``. On headless hosts the gateway
        runs as the kirocrew service user, so the CLI is run as kirocrew; on
        workstation profiles it runs as orre with a login environment. The
        gateway binds the dashboard on PORTAL_PORT (5476), but access is
        through the SSM tunnel on PORTAL_LOCAL_PORT (7780) — the token is
        signature-validated, not port-bound, so we rewrite the host port to the
        local one for a paste-ready URL.
        """
        remote = self._remote(state)
        print("\n» Minting a KiroCrew dashboard token on the instance...")
        # System profile (EC2/headless): kirocrew-gateway runs as the kirocrew
        # user from the source-built venv binary. Workstation profile: the
        # kirocrew CLI is on the orre user's PATH. Try the system layout first,
        # then fall back, mirroring _restart_kirocrew.
        remote_script = f"""set -e
BIN={shlex.quote(REMOTE_KIROCREW_BIN)}
PORT={shlex.quote(PORTAL_PORT)}
HOME_DIR={shlex.quote(REMOTE_KIROCREW_HOME)}
# LD_LIBRARY_PATH: the v0.7 dashboard code path `kirocrew token` imports pulls in
# numpy (via the STT engine), whose C-extension needs libstdc++.so.6. The
# gateway UNIT sets this in its own Environment, but our invocation does not
# source environment.shellInit (where kirocrew.nix exports it), so numpy fails
# with "libstdc++.so.6: cannot open shared object file" without it.
# /run/current-system/sw/lib is the stable, rebuild-independent system path.
LD=/run/current-system/sw/lib
if [ -x "$BIN" ]; then
  # System/headless profile: the gateway runs as the `kirocrew` user INSIDE a
  # private mount-namespace sandbox. Since v0.7, `/api/token/local` refuses any
  # caller that is not a "verified host process" — on Linux that means sharing
  # the gateway's user AND mount namespaces (member_memory_auth
  # .local_owner_bootstrap_allowed -> platform_compat.process_namespaces_match).
  # A fresh `sudo -u kirocrew kirocrew token` runs in the host mount namespace,
  # so it is refused with `member_owner_token_refused`. (This gate activates
  # once any V2 private-memory store exists, e.g. a registered crew.)
  #
  # Fix: run `kirocrew token` INSIDE the gateway's namespaces so it IS a verified
  # host process. The gateway is on the host USER ns but a private MOUNT ns, so
  # enter -m (mount) and -p (pid) only — NOT -U — keeping root's credentials,
  # then drop to the kirocrew user with runuser. Absolute Nix-store paths and an
  # explicit env are required because the mount namespace does not carry the
  # invoking shell's PATH. Fall back to a direct run if the gateway PID or
  # nsenter is unavailable (e.g. a not-yet-hardened build) — it simply reproduces
  # the prior behaviour rather than failing outright.
  cd "$HOME_DIR"
  GPID="$(systemctl show kirocrew-gateway.service -p MainPID --value 2>/dev/null || true)"
  if [ -n "$GPID" ] && [ "$GPID" != 0 ] && command -v nsenter >/dev/null 2>&1 \
     && command -v runuser >/dev/null 2>&1 && [ -r "/proc/$GPID/ns/mnt" ]; then
    nsenter -t "$GPID" -m -p --preserve-credentials -- \
      runuser -u kirocrew -- \
        env HOME="$HOME_DIR" KIROCREW_HOME="$HOME_DIR/.kiro/crew" \
            KIROCREW_PORT="$PORT" LD_LIBRARY_PATH="$LD" \
        "$BIN" token --port "$PORT"
  else
    # Fallback (no hardened owner gate, or nsenter/runuser missing).
    sudo -u kirocrew -H env HOME="$HOME_DIR" KIROCREW_PORT="$PORT" \
      LD_LIBRARY_PATH="$LD" \
      "$BIN" token --port "$PORT"
  fi
else
  cd /home/orre
  sudo -u orre -H env LD_LIBRARY_PATH="$LD" \
    kirocrew token --port "$PORT"
fi
"""
        result = remote.run("root", remote_script, capture=True, check=False)
        if result.returncode != 0:
            detail = (result.stderr or "").strip() or "unknown error"
            raise LauncherError(f"Failed to mint dashboard token: {detail}")

        url = self._extract_token_url(result.stdout)
        if url is None:
            raise LauncherError(
                "kirocrew token produced no dashboard URL; output was:\n"
                f"{result.stdout.strip()}"
            )

        # The dashboard is reached locally through the SSM tunnel on
        # PORTAL_LOCAL_PORT; rewrite the host port so the URL is paste-ready
        # against `launch-ec2 portal` / `launch-portal`.
        local_url = url.replace(
            f":{PORTAL_PORT}?", f":{PORTAL_LOCAL_PORT}?", 1
        )
        print("  ✓ Token minted (default TTL 20h)\n")
        print("KiroCrew dashboard sign-in URL (paste into the banner):")
        print(f"  {local_url}")
        if local_url != url:
            print("\n  Raw gateway URL (loopback on the box):")
            print(f"  {url}")
        print(
            f"\n  Ensure the tunnel is up first: "
            f"{self.script_dir / 'launch-ec2'} portal"
        )

    @staticmethod
    def _extract_token_url(output: str) -> str | None:
        """Return the dashboard URL line from `kirocrew token` output.

        The command prints warnings on stderr and the URL on stdout, but be
        defensive: pick the last line that looks like a dashboard URL carrying
        a token query parameter.
        """
        candidate: str | None = None
        for line in output.splitlines():
            stripped = line.strip()
            if stripped.startswith(("http://", "https://")) and "token=" in stripped:
                candidate = stripped
        return candidate

    @staticmethod
    def _open_browser(url: str) -> None:
        """Open the URL in the default browser, or print it if that fails."""
        import webbrowser

        if not webbrowser.open(url):
            print(f"  Open this URL in your browser: {url}")

    # ── Deploy workflow ────────────────────────────────────────────────────────

    def _deploy(self, state: InstanceState) -> None:
        self.resources.ensure_iam()
        key_pair_id, key_fingerprint = self.resources.ensure_key_pair()
        sg_id = self.resources.ensure_security_group()
        self.resources.attach_security_group(state.instance_id, sg_id)
        state = state.updated(
            security_group_id=sg_id,
            key_pair_id=key_pair_id,
            key_fingerprint=key_fingerprint,
        )
        self.store.save(state)
        self.saved_state = state
        remote = self._remote(state)
        self._bootstrap_age_key(remote)
        self._rebuild_nixos(remote)
        self._restart_kirocrew(remote)
        self._sync_state(state)
        failures = self._sync_repositories(remote)
        self._restart_pasta(remote)
        self._setup_code_review_graph(remote)
        self._register_project_dirs(remote)
        self._normalize_session_paths(remote)
        self._print_result(state, failures)

    def _bootstrap_age_key(self, remote: RemoteHost) -> None:
        print("\n» Ensuring age decryption key is on the remote...")
        present = remote.run(
            "root",
            "test -f /home/orre/.config/sops/age/keys.txt && echo yes || echo no",
            capture=True,
        ).stdout.strip()
        if present == "yes":
            print("  ✓ Age key already present")
            return
        age_key = ""
        if shutil.which("op") is not None:
            result = self.runner.run(
                ["op", "read", "op://Readpeak/kirocrew-age/private key"],
                capture=True,
                check=False,
            )
            if result.returncode == 0:
                age_key = result.stdout
        if not age_key:
            local = Path.home() / ".config" / "sops" / "age" / "keys.txt"
            if local.exists():
                age_key = local.read_text()
        if not age_key:
            raise LauncherError("No age key available")
        remote.run(
            "root",
            "set -e; install -d -m 700 -o orre -g users /home/orre/.config/sops/age; "
            "cat > /home/orre/.config/sops/age/keys.txt; "
            "chmod 600 /home/orre/.config/sops/age/keys.txt; "
            "chown orre:users /home/orre/.config/sops/age/keys.txt",
            input_text=age_key,
        )
        print("  ✓ Age key placed on remote")

    def _rebuild_nixos(self, remote: RemoteHost) -> None:
        print("\n» Rebuilding NixOS config on the remote through SSM...")
        self.runner.run(
            [
                "nix", "run", "nixpkgs#nixos-rebuild", "--", "switch",
                "--flake", f"{self.flake_dir}#kirocrew-ec2",
                "--target-host", f"root@{remote.instance_id}",
                "--build-host", f"root@{remote.instance_id}",
            ],
            env=inherited_environment(NIX_SSHOPTS=remote.nix_ssh_options()),
        )

    def _restart_kirocrew(self, remote: RemoteHost) -> None:
        print("\n» Restarting KiroCrew service...")
        # Try the system service first (EC2/headless hosts use kirocrew-gateway),
        # fall back to the user service (workstation profiles use kirocrew.service
        # under the orre user).
        remote.run(
            "root",
            """set -e
if systemctl list-unit-files kirocrew-gateway.service >/dev/null 2>&1 && \
   systemctl is-enabled kirocrew-gateway.service >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl restart kirocrew-gateway.service
  systemctl is-active --quiet kirocrew-gateway.service
else
  uid=$(id -u orre)
  systemctl start "user@${uid}.service"
  sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user daemon-reload
  sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user restart kirocrew.service
  sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user is-active --quiet kirocrew.service
fi
""",
        )
        print("  ✓ KiroCrew service restarted and verified active")

    def _restart_pasta(self, remote: RemoteHost) -> None:
        """Start or restart the pasta daemon (system or user service)."""
        print("\n» Starting pasta daemon...")
        remote.run(
            "root",
            """set -e
# Try system service first (EC2/headless), then user service (workstation).
if systemctl list-unit-files pasta-daemon.service >/dev/null 2>&1 && \
   systemctl is-enabled pasta-daemon.service >/dev/null 2>&1; then
  systemctl restart pasta-daemon.service
  echo "pasta-daemon system service restarted"
else
  uid=$(id -u orre)
  if sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
     systemctl --user list-unit-files pasta.service >/dev/null 2>&1; then
    sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
      systemctl --user restart pasta.service
    echo "pasta user service restarted"
  else
    echo "pasta service not found (first deploy — will start after next rebuild)"
  fi
fi
""",
            check=False,
        )
        print("  ✓ Pasta daemon started")

    def _sync_repositories(self, remote: RemoteHost) -> list[str]:
        """Run the declarative protected-mirror and checkout services."""
        print("\n» Syncing code repositories...")
        result = remote.run(
            "root",
            r"""fetch_failed=0
sync_failed=0
systemctl restart repo-fetch.service || fetch_failed=1
systemctl start repo-sync.service || sync_failed=1
systemctl is-active --quiet repo-fetch.timer || true
if [ "$fetch_failed" -ne 0 ] || [ "$sync_failed" -ne 0 ]; then
  exit 1
fi
""",
            capture=True,
            check=False,
        )
        if result.returncode != 0:
            print("  ⚠ One or more repository operations need attention")
            return ["repo-sync"]
        print("  ✓ All repositories ready")
        return []

    # ── Code Review Graph ────────────────────────────────────────────────────

    def _setup_code_review_graph(self, remote: RemoteHost) -> None:
        """Install code-review-graph and build graphs for repos that lack one."""
        print("\n» Setting up code-review-graph...")
        # Clean up the legacy orre-owned CRG install/state. CRG used to run as
        # the orre user; it now runs as kirocrew (see kirocrew-code.nix), so the
        # old binary, uv tool venv, and daemon state under /home/orre are dead.
        # Best-effort: a fresh box or an already-cleaned box just skips these.
        remote.run(
            "root",
            r"""set +e
# Stop any lingering orre-side daemon still registered from the old layout.
sudo -u orre -H env PATH="/home/orre/.local/bin:/run/current-system/sw/bin:$PATH" \
  code-review-graph daemon stop >/dev/null 2>&1
# Uninstall the old uv tool (removes the venv + the ~/.local/bin shim).
sudo -u orre -H env PATH="/etc/profiles/per-user/orre/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH" \
  uv tool uninstall code-review-graph >/dev/null 2>&1
# Remove orphaned state and any leftover binary/venv.
rm -rf /home/orre/.code-review-graph \
       /home/orre/.local/share/uv/tools/code-review-graph \
       /home/orre/.local/bin/code-review-graph
true
""",
        )
        # Install the validated version used by the declarative service, as the
        # kirocrew user (the CRG sync/daemon units and the gateway all run as
        # kirocrew). `uv tool install` drops the binary at
        # /var/lib/kirocrew/.local/bin/code-review-graph, which the units
        # reference. uv itself is provided system-wide (environment.systemPackages
        # in kirocrew.nix), so it is on the default Nix path for any user.
        # --force ensures a clean reinstall, repairing a partial/corrupt env.
        #
        # NOTE: the declarative code-review-graph-install.service also performs
        # this install (ordered before the sync/daemon units, so activation
        # succeeds on a fresh box). This launcher step is kept as a belt-and-
        # suspenders early install; both are idempotent.
        remote.run(
            "root",
            r"""set -e
sudo -u kirocrew -H env \
  HOME=/var/lib/kirocrew \
  PATH="/var/lib/kirocrew/.local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH" \
  uv tool install --force code-review-graph==2.3.8 2>&1 | tail -3
""",
        )
        # Run the declarative units immediately after deployment instead of
        # duplicating their repository discovery and graph lifecycle logic here.
        remote.run(
            "root",
            r"""set -e
systemctl restart repo-fetch.service || true
systemctl start repo-sync.service || true
systemctl start code-review-graph-sync.service || true
systemctl restart code-review-graph-daemon.service
systemctl is-active --quiet code-review-graph-daemon.service
""",
        )
        print("  ✓ code-review-graph ready and supervised")

    # ── Project directory registration ─────────────────────────────────────
    def _register_project_dirs(self, remote: RemoteHost) -> None:
        """Expose the code repos and the vault to the gateway agent.

        The gateway runs as `kirocrew` and works out of its workspace dir.
        Repos live in the shared /var/lib/code tree (readable/writable via the
        code-writers group) and the writable vault at /var/lib/vault is owned
        by kirocrew. We surface both inside the workspace as symlinks and add
        their real roots to agent.subagent_cwd_allowed_roots so subagents may
        cd into them.
        """
        print("\n» Registering project directories (code + vault)...")
        crew_dir = f"{REMOTE_KIROCREW_HOME}/.kiro/crew"
        workspace = f"{crew_dir}/workspace"
        # The gateway reads its config from ${KIROCREW_HOME}/config.json, where
        # KIROCREW_HOME=/var/lib/kirocrew/.kiro/crew (see kirocrew-services.nix).
        # An earlier value here (/var/lib/kirocrew/config.json) targeted a stray
        # file the gateway never reads — so subagent_cwd_allowed_roots edits
        # silently had no effect (and hit a PermissionError on that 0600 file).
        config = f"{crew_dir}/config.json"
        script = f"""set -e
WORKSPACE={shlex.quote(workspace)}
CONFIG={shlex.quote(config)}
CODE_DIR={shlex.quote(REMOTE_CODE_DIR)}
VAULT_DIR={shlex.quote(REMOTE_VAULT_DIR)}

# Link each repo and the vault into the gateway workspace so the agent sees
# them as project folders. Links (and config) are owned by kirocrew.
sudo -u kirocrew -H bash -s <<'KC'
set -e
WORKSPACE="{workspace}"
CONFIG="{config}"
CODE_DIR="{REMOTE_CODE_DIR}"
VAULT_DIR="{REMOTE_VAULT_DIR}"
mkdir -p "$WORKSPACE/code"
for repo in "$CODE_DIR"/*/; do
  [ -d "$repo" ] || continue
  name=$(basename "$repo")
  ln -sfn "$repo" "$WORKSPACE/code/$name"
  echo "  ✓ linked code/$name"
done
if [ -d "$VAULT_DIR" ]; then
  ln -sfn "$VAULT_DIR" "$WORKSPACE/vault"
  echo "  ✓ linked vault"
fi

# Add /var/lib/code and /var/lib/vault to agent.subagent_cwd_allowed_roots
# (idempotent) so subagents can cd into the linked targets.
python3 - "$CONFIG" "$CODE_DIR" "$VAULT_DIR" <<'PY'
import json, sys
config_path, code_dir, vault_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(config_path) as fh:
        data = json.load(fh)
except FileNotFoundError:
    print(f"  ⚠ gateway config not found, skipping roots update: {{config_path}}")
    sys.exit(0)
except PermissionError:
    print(f"  ⚠ cannot read gateway config (permission denied), skipping: {{config_path}}")
    sys.exit(0)
agent = data.setdefault("agent", {{}})
roots = agent.setdefault("subagent_cwd_allowed_roots", [])
changed = False
for root in (code_dir, vault_dir):
    if root not in roots:
        roots.append(root)
        changed = True
if changed:
    try:
        with open(config_path, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\\n")
    except PermissionError:
        print(f"  ⚠ cannot write gateway config (permission denied): {{config_path}}")
        sys.exit(0)
    print("  ✓ updated subagent_cwd_allowed_roots")
else:
    print("  ✓ subagent_cwd_allowed_roots already current")
PY
KC
"""
        remote.run("root", script, check=False)
        print("  ✓ project directories registered")

        # The gateway reads config.json (incl. subagent_cwd_allowed_roots) at
        # startup, not live. _restart_kirocrew ran earlier in the sequence — i.e.
        # before this config write — so restart once more here to pick up the
        # newly registered roots and workspace links this deploy rather than the
        # next one. Best-effort: a failure here must not fail the whole deploy.
        remote.run(
            "root",
            """set -e
if systemctl list-unit-files kirocrew-gateway.service >/dev/null 2>&1 && \
   systemctl is-enabled kirocrew-gateway.service >/dev/null 2>&1; then
  systemctl restart kirocrew-gateway.service
  systemctl is-active --quiet kirocrew-gateway.service
fi
""",
            check=False,
        )
        print("  ✓ gateway reloaded to apply registered roots")

    # ── Session path normalization ──────────────────────────────────────────
    def _normalize_session_paths(self, remote: RemoteHost) -> None:
        """Rewrite stale legacy code-tree roots in the gateway's session state.

        Earlier deploys pinned per-session working directories to legacy roots
        (see LEGACY_CODE_DIRS). After the move to REMOTE_CODE_DIR those paths no
        longer exist and sit on a read-only mount, so resuming such a session
        crashes when the ACP runtime tries to mkdir the missing project dir.

        This rewrites the legacy prefix to REMOTE_CODE_DIR in three places the
        gateway reads a project/cwd from:
          - session_map.json         (resume cwd via SessionMap.get_cwd)
          - recent_projects.json     (the project picker)
          - sessions/*.jsonl         (only the line-0 `project` header)

        It is idempotent and conservative: message/transcript content in the
        .jsonl files is never touched, per-file backups are written, and a
        rewritten path that still does not exist falls back to REMOTE_CODE_DIR
        so a stale sub-path (e.g. a deleted MR worktree) never re-introduces a
        broken project dir. Runs as kirocrew (the owner of the state).
        """
        print("\n» Normalizing gateway session paths...")
        crew_dir = f"{REMOTE_KIROCREW_HOME}/.kiro/crew"
        legacy_arg = ",".join(LEGACY_CODE_DIRS)
        script = f"""set -e
sudo -u kirocrew -H python3 - {shlex.quote(crew_dir)} {shlex.quote(REMOTE_CODE_DIR)} {shlex.quote(legacy_arg)} <<'PY'
import json, os, sys, time

crew_dir, code_dir, legacy_arg = sys.argv[1], sys.argv[2], sys.argv[3]
legacy = [p for p in legacy_arg.split(",") if p]
ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def remap(path):
    # Return (new_path, changed). Map a legacy prefix onto code_dir; if the
    # remapped path does not exist, fall back to code_dir so we never write a
    # path that would crash on resume. Leave non-legacy paths untouched.
    if not isinstance(path, str):
        return path, False
    for old in legacy:
        if path == old or path.startswith(old + "/"):
            candidate = code_dir + path[len(old):]
            if not os.path.isdir(candidate):
                candidate = code_dir
            return candidate, candidate != path
    return path, False


def backup(p):
    try:
        import shutil
        shutil.copy2(p, f"{{p}}.bak-{{ts}}")
    except OSError:
        pass


changed_total = 0

# 1) session_map.json — cwd values inside the map structure.
smap = os.path.join(crew_dir, "session_map.json")
if os.path.isfile(smap):
    with open(smap) as fh:
        data = json.load(fh)
    n = 0

    def walk(obj):
        global n
        if isinstance(obj, dict):
            for k, v in list(obj.items()):
                if isinstance(v, str) and k in ("cwd", "project", "project_dir"):
                    nv, ch = remap(v)
                    if ch:
                        obj[k] = nv
                        n += 1
                else:
                    walk(v)
        elif isinstance(obj, list):
            for v in obj:
                walk(v)

    walk(data)
    if n:
        backup(smap)
        with open(smap, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\\n")
        print(f"  ✓ session_map.json: {{n}} path(s) rewritten")
        changed_total += n

# 2) recent_projects.json — a flat list of project dir strings.
recent = os.path.join(crew_dir, "recent_projects.json")
if os.path.isfile(recent):
    with open(recent) as fh:
        data = json.load(fh)
    if isinstance(data, list):
        new = []
        n = 0
        for entry in data:
            nv, ch = remap(entry)
            if ch:
                n += 1
            if nv not in new:
                new.append(nv)
        if n:
            backup(recent)
            with open(recent, "w") as fh:
                json.dump(new, fh)
            print(f"  ✓ recent_projects.json: {{n}} path(s) rewritten")
            changed_total += n

# 3) sessions/*.jsonl — only the line-0 `project` header.
sessions_dir = os.path.join(crew_dir, "sessions")
if os.path.isdir(sessions_dir):
    files = 0
    for name in sorted(os.listdir(sessions_dir)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(sessions_dir, name)
        try:
            with open(path) as fh:
                lines = fh.readlines()
        except OSError:
            continue
        if not lines or not lines[0].strip():
            continue
        try:
            hdr = json.loads(lines[0].strip())
        except Exception:
            continue
        proj = hdr.get("project")
        nv, ch = remap(proj)
        if not ch:
            continue
        hdr["project"] = nv
        first = json.dumps(hdr, ensure_ascii=False)
        if lines[0].endswith("\\n"):
            first += "\\n"
        backup(path)
        lines[0] = first
        with open(path, "w") as fh:
            fh.writelines(lines)
        files += 1
    if files:
        print(f"  ✓ sessions: {{files}} project header(s) rewritten")
        changed_total += files

if changed_total == 0:
    print("  ✓ session paths already current")
PY
"""
        remote.run("root", script, check=False)

    # ── MCP OAuth provisioning ─────────────────────────────────────────────

    def _auth(self, state: InstanceState) -> None:
        """Bootstrap or repair MCP OAuth tokens on the gateway.

        With no target, every entry in AUTH_SERVER_URLS is processed.

        The gateway is asked FIRST, and that ordering is the whole design. It
        maintains its own tokens — long-lived `mcp-remote` processes there
        refresh them on use — so the common case is that it needs nothing, and
        this command must then be a genuine no-op: no browser, no overwrite, no
        restart. Its real job is the initial authorisation, which the gateway
        cannot perform itself because it is headless and cannot open a browser,
        plus repair when its token is genuinely broken.

        Validity is decided by USING a token, never by inspecting the cache
        directory. The previous "a new token file appeared" test was wrong in
        both directions: mcp-remote reuses a still-valid token without
        rewriting it (reported as "OAuth did not complete" despite a working
        credential), and an expired token that merely got rewritten looked like
        success — which would install a 401-ing token and report that the tools
        should now connect.
        """
        requested = self.arguments.auth_target
        targets = [requested] if requested else list(AUTH_TARGETS)
        for target in targets:
            if target not in AUTH_SERVER_URLS:
                raise LauncherError(f"Unknown auth target: {target!r}")

        if shutil.which("npx") is None:
            raise LauncherError("npx is required to run the mcp-remote OAuth flow")

        auth_dir = Path(os.path.expanduser(LOCAL_MCP_AUTH_DIR))
        installed: list[str] = []
        healthy: list[str] = []
        failures: dict[str, str] = {}

        for target in targets:
            server_url = AUTH_SERVER_URLS[target]
            token_path = self._token_path(auth_dir, server_url)
            remote_token_path = f"{REMOTE_MCP_AUTH_DIR}/{token_path.name}"
            print(f"\n» {target}:")

            remote_remaining: float | None = None
            if not self.arguments.force:
                # Ask the GATEWAY first. It refreshes its own tokens, so in the
                # common case there is nothing to do — and doing something would
                # be actively harmful: a browser login here, an overwrite of a
                # fresher token there, and a gateway restart that drops live
                # sessions, all for a credential that already works.
                print("  checking the gateway's own token...")
                status, detail, remote_remaining = self._probe_remote_token(
                    state, server_url, remote_token_path
                )
                if status == "ok":
                    print(f"  ✓ gateway token is valid ({detail}); nothing to do.")
                    healthy.append(target)
                    continue
                print(f"  gateway token needs attention ({status}: {detail}).")

            if self.arguments.force:
                removed = self._clear_mcp_cache(auth_dir, server_url)
                print(
                    f"  Cleared {removed} cached auth file(s) to force re-login."
                    if removed
                    else "  No cached auth files to clear; proceeding."
                )
            else:
                status, detail, _ = self._probe_token(server_url, token_path)
                if status == "ok":
                    print(f"  ✓ local token valid ({detail}); installing it.")
                    if self._install_guarded(
                        state, token_path, target, remote_remaining, failures
                    ):
                        installed.append(target)
                    continue
                if status == "unknown":
                    # The probe could not reach the server. Refusing to guess is
                    # the point: a browser login would not fix a network fault,
                    # and installing an unverified token is what we removed.
                    failures[target] = detail
                    print(f"  ✗ {target}: {detail}")
                    continue
                print(f"  local token needs renewing ({detail}).")

                # An EXPIRED token often renews silently from its refresh token,
                # so try that before sending anyone to a browser. A STALE one
                # cannot: mcp-remote reuses a token that is still valid instead
                # of refreshing it, so its cache has to be cleared first.
                if status == "expired":
                    print("  attempting a silent refresh from the cached refresh token...")
                    try:
                        self._run_mcp_remote(server_url, self._browser_env())
                    except KeyboardInterrupt:
                        pass
                    status, detail, _ = self._probe_token(server_url, token_path)
                    if status == "ok":
                        print(f"  ✓ refreshed without a browser ({detail}).")
                        if self._install_guarded(
                            state, token_path, target, remote_remaining, failures
                        ):
                            installed.append(target)
                        continue
                    print(f"  silent refresh insufficient ({detail}); falling back to login.")

                removed = self._clear_mcp_cache(auth_dir, server_url)
                if removed:
                    print(f"  Cleared {removed} cached auth file(s) to force a fresh login.")

            print(f"  complete the {target} login/consent in the browser.")
            print("  the proxy stops automatically once the token is cached")
            print("  (press Ctrl+C to stop early if needed).")
            try:
                self._run_mcp_remote(server_url, self._browser_env())
            except KeyboardInterrupt:
                pass

            status, detail, _ = self._probe_token(server_url, token_path)
            if status not in ("ok", "stale"):
                failures[target] = detail
                print(f"  ✗ {target}: {detail}")
                continue
            if status == "stale":
                # A provider whose whole token lifetime is shorter than the floor
                # lands here even immediately after a successful login. Install
                # it — it is the best this provider can issue — but say so,
                # because the gateway's copy expires that soon.
                print(
                    f"  ! {target}: freshly issued token is already short-lived "
                    f"({detail}); installing anyway."
                )
            else:
                print(f"  ✓ local token valid ({detail}).")
            if self._install_guarded(
                state, token_path, target, remote_remaining, failures
            ):
                installed.append(target)

        # Restart once for the whole batch rather than per target: each restart
        # drops live agent sessions, so N targets must not mean N interruptions.
        # Skipped entirely when nothing was installed — a run that found every
        # gateway token healthy must not disturb the gateway at all.
        if installed:
            print("\n» Restarting the gateway to pick up the token(s)...")
            self._remote(state).run(
                "root",
                "set -e; systemctl restart kirocrew-gateway.service; "
                "systemctl is-active --quiet kirocrew-gateway.service",
            )
            print(f"  ✓ Gateway restarted; {', '.join(installed)} tools should connect")
        elif healthy:
            print(
                f"\n  ✓ Nothing to do — {', '.join(healthy)} already valid on the "
                "gateway; it was not restarted."
            )
        else:
            print("\n  Nothing installed; gateway left running as-is.")

        if failures:
            summary = "; ".join(f"{name}: {why}" for name, why in failures.items())
            raise LauncherError(f"auth failed for {len(failures)} target(s) — {summary}")

    def _install_guarded(
        self,
        state: InstanceState,
        token_path: Path,
        target: str,
        remote_remaining: float | None,
        failures: dict[str, str],
    ) -> bool:
        """Install a token unless the gateway's copy is fresher. Returns installed.

        The gateway refreshes its own tokens, so a local snapshot can easily be
        the older of the two. Replacing a longer-lived remote token with a
        shorter-lived local one is a downgrade, and with a shared refresh-token
        lineage it risks invalidating the gateway's refresh chain.
        """
        _, detail, local_remaining = self._probe_token(
            AUTH_SERVER_URLS[target], token_path
        )
        if (
            remote_remaining is not None
            and local_remaining is not None
            and remote_remaining > local_remaining
        ):
            print(
                f"  · skipping install: the gateway's token has "
                f"{remote_remaining / 3600:.1f}h left vs {local_remaining / 3600:.1f}h "
                "locally — refusing to downgrade it."
            )
            return False
        self._install_token(state, token_path, target)
        return True

        # Restart once for the whole batch rather than per target: each restart
        # drops live agent sessions, so N targets must not mean N interruptions.
        if installed:
            print("\n» Restarting the gateway to pick up the token(s)...")
            self._remote(state).run(
                "root",
                "set -e; systemctl restart kirocrew-gateway.service; "
                "systemctl is-active --quiet kirocrew-gateway.service",
            )
            print(f"  ✓ Gateway restarted; {', '.join(installed)} tools should connect")
        else:
            print("\n  Nothing installed; gateway left running as-is.")

        if failures:
            summary = "; ".join(f"{name}: {why}" for name, why in failures.items())
            raise LauncherError(f"auth failed for {len(failures)} target(s) — {summary}")

    @staticmethod
    def _browser_env() -> dict[str, str]:
        """Spawn environment for mcp-remote's browser hand-off.

        mcp-remote opens the browser via the OS default handler, so make the
        choice explicit — launch-ec2 may have been started from a minimal
        environment where no default resolves.
        """
        env = inherited_environment()
        env.setdefault("BROWSER", "firefox")
        return env

    def _install_token(
        self, state: InstanceState, token_path: Path, target: str
    ) -> None:
        """Copy one validated token file to the gateway's mcp-remote cache."""
        remote_path = f"{REMOTE_MCP_AUTH_DIR}/{token_path.name}"
        print(f"  » installing {target} token on the gateway...")
        with token_path.open("rb") as handle:
            self._remote(state).run(
                "root",
                "set -e; "
                f"install -d -m 700 -o kirocrew -g kirocrew {shlex.quote(REMOTE_MCP_AUTH_DIR)}; "
                f"install -m 600 -o kirocrew -g kirocrew /dev/stdin {shlex.quote(remote_path)}",
                stdin=handle,
            )
        print(f"    ✓ {remote_path}")

    def _token_path(self, auth_dir: Path, server_url: str) -> Path:
        """Path of the token file mcp-remote caches for exactly this server.

        Scoping by cache key matters: the directory holds one set of files per
        server, and picking "the most recently changed file" instead could
        select a SIBLING server's token and install it under that sibling's
        name — the wrong credential, with no error.
        """
        return auth_dir / f"{self._mcp_cache_key(server_url)}_tokens.json"

    @staticmethod
    def _probe_token(server_url: str, token_path: Path) -> tuple[str, str, float | None]:
        """Classify the workstation's cached token. See `token_probe.classify`."""
        return classify(server_url, token_path, AUTH_MIN_REMAINING_SECS)

    def _probe_remote_token(
        self, state: InstanceState, server_url: str, remote_token_path: str
    ) -> tuple[str, str, float | None]:
        """Classify the token as the GATEWAY sees it, using the same rules.

        Asked before any local work because the gateway maintains its own
        tokens: long-lived `mcp-remote` processes there refresh them on use, so
        a healthy gateway needs nothing from us. Overwriting it would replace a
        freshly-refreshed token with a staler local snapshot — and because both
        hosts share a refresh-token lineage, a provider that rotates refresh
        tokens on use could then invalidate the gateway's ability to refresh at
        all, breaking the very mechanism that was working.

        The probe module is shipped base64-encoded on the command line rather
        than piped, because RemoteHost.run cannot both capture stdout and write
        stdin. Runs as root: the token files are 0600 and owned by kirocrew.
        """
        source = Path(__file__).with_name("token_probe.py").read_bytes()
        encoded = base64.b64encode(source).decode("ascii")
        command = (
            f"echo {shlex.quote(encoded)} | base64 -d | "
            f"python3 - {shlex.quote(server_url)} {shlex.quote(remote_token_path)} "
            f"{int(AUTH_MIN_REMAINING_SECS)}"
        )
        try:
            result = self._remote(state).run("root", command, capture=True, check=False)
        except Exception as error:  # transport/SSM failure
            return "unknown", f"remote probe failed: {type(error).__name__}: {error}", None
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip().splitlines()
            return (
                "unknown",
                f"remote probe exited {result.returncode}: {detail[-1][:120] if detail else 'no output'}",
                None,
            )
        line = (result.stdout or "").strip().splitlines()
        if not line:
            return "unknown", "remote probe produced no output", None
        parts = line[-1].split("\t")
        if len(parts) < 2:
            return "unknown", f"unparseable remote probe output: {line[-1][:120]}", None
        remaining = None
        if len(parts) > 2 and parts[2]:
            try:
                remaining = float(parts[2])
            except ValueError:
                remaining = None
        return parts[0], parts[1], remaining

    @staticmethod
    def _mcp_cache_key(server_url: str) -> str:
        """Reproduce mcp-remote's cache key: md5 hex of the server URL."""
        import hashlib

        return hashlib.md5(server_url.encode("utf-8")).hexdigest()

    def _clear_mcp_cache(self, auth_dir: Path, server_url: str) -> int:
        """Delete the cached token/client_info/code_verifier for one server.

        Targets only files whose name begins with md5(server_url), so other
        servers' cached credentials are left intact. Returns the number of
        files removed.
        """
        if not auth_dir.is_dir():
            return 0
        key = self._mcp_cache_key(server_url)
        removed = 0
        for entry in auth_dir.iterdir():
            if entry.is_file() and entry.name.startswith(key):
                try:
                    entry.unlink()
                    removed += 1
                except OSError:
                    pass
        return removed

    def _run_mcp_remote(self, server_url: str, env: dict[str, str]) -> None:
        """Run `npx mcp-remote <url>`, echoing output and opening any auth URL.

        mcp-remote normally opens the browser itself; when that auto-open
        fails (or is skipped), it prints the authorization URL. We stream its
        output, forward it to the terminal, and explicitly open the first
        authorization URL we see so the operator always lands in the browser.

        mcp-remote has no "auth then exit" mode — it stays up as a stdio proxy
        forever, which previously forced the operator to press Ctrl+C to
        advance. Instead we watch for the post-authorization signals and, once
        the cached token file has actually appeared on disk, terminate the
        process ourselves so the flow continues automatically. Ctrl+C still
        works as a manual fallback.
        """
        import re
        import threading

        auth_dir = Path(os.path.expanduser(LOCAL_MCP_AUTH_DIR))
        token_key = self._mcp_cache_key(server_url)

        opened = False
        authorized = False
        url_pattern = re.compile(r"https://\S*(?:oauth|authorize|/auth)\S*")
        # Signals that the browser step is done and the token has been written.
        done_pattern = re.compile(
            r"resolving promise|Completing authorization|Proxy established successfully",
            re.IGNORECASE,
        )

        proc = subprocess.Popen(
            ["npx", "-y", "mcp-remote", server_url],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )

        def token_present() -> bool:
            if not auth_dir.is_dir():
                return False
            return any(
                entry.name.startswith(token_key) and "tokens" in entry.name
                for entry in auth_dir.iterdir()
            )

        def stop_after_auth() -> None:
            # Give mcp-remote a moment to flush the token to disk, then stop it.
            for _ in range(20):  # up to ~10s
                if token_present():
                    break
                time.sleep(0.5)
            print("  Authorization complete; stopping the proxy automatically.")
            if proc.poll() is None:
                proc.terminate()

        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                print(line, end="")
                if not opened:
                    match = url_pattern.search(line)
                    if match:
                        opened = True
                        print(
                            f"  Opening authorization URL in browser: {match.group(0)}"
                        )
                        self._open_browser(match.group(0))
                if not authorized and done_pattern.search(line):
                    authorized = True
                    # Stop in a helper thread so we keep draining stdout (the
                    # process may print a few more lines before it exits).
                    threading.Thread(target=stop_after_auth, daemon=True).start()
            proc.wait()
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

    # ── State sync ───────────────────────────────────────────────────────────

    def _sync_state(self, state: InstanceState) -> None:
        """Sync local kirocrew config, skills, and workspace to the remote."""
        remote = self._remote(state)
        crew_dir = Path.home() / ".kiro" / "crew"
        print("\n» Syncing KiroCrew state to remote...")

        # 1. Config (contains auth tokens)
        config_file = crew_dir / "config.json"
        if config_file.exists():
            print("  Syncing config.json...")
            remote.run(
                "orre",
                "cp ~/.kiro/crew/config.json ~/.kiro/crew/config.json.bak 2>/dev/null; "
                "cat > ~/.kiro/crew/config.json",
                input_text=config_file.read_text(),
            )
            print("  ✓ config.json")

        # 2. Skills (rsync-like: send any missing skill directories)
        local_skills = crew_dir / "skills"
        if local_skills.is_dir():
            local_skill_names = {d.name for d in local_skills.iterdir() if d.is_dir()}
            remote_list = remote.run(
                "orre", "ls ~/.kiro/crew/skills/ 2>/dev/null || true", capture=True
            ).stdout.strip()
            remote_skill_names = set(remote_list.splitlines()) if remote_list else set()
            missing = sorted(local_skill_names - remote_skill_names)
            if missing:
                print(f"  Syncing {len(missing)} missing skills...")
                for skill_name in missing:
                    self._send_directory(remote, local_skills / skill_name,
                                         f".kiro/crew/skills/{skill_name}")
                print(f"  ✓ {len(missing)} skills synced: {', '.join(missing)}")
            else:
                print("  ✓ Skills already in sync")

        # 3. Workspace subdirectories (memory, tasks, knowledge)
        local_workspace = crew_dir / "workspace"
        for subdir in ("memory", "tasks", "knowledge"):
            local_sub = local_workspace / subdir
            if local_sub.is_dir():
                print(f"  Syncing workspace/{subdir}...")
                self._send_directory(remote, local_sub, f".kiro/crew/workspace/{subdir}")
                print(f"  ✓ workspace/{subdir}")

        print("\n✓ State sync complete")

    def _send_directory(self, remote: RemoteHost, local_path: Path, remote_rel: str) -> None:
        """Send a local directory to the remote via tar over SSH."""
        tar_result = self.runner.run_bytes(
            ["tar", "czf", "-", "-C", str(local_path.parent), local_path.name]
        )
        with tempfile.NamedTemporaryFile(suffix=".tar.gz") as tmp:
            tmp.write(tar_result.stdout)
            tmp.flush()
            tmp.seek(0)
            remote.run(
                "orre",
                f"mkdir -p ~/{shlex.quote(remote_rel)} && "
                f"tar xzf - -C ~/{shlex.quote(Path(remote_rel).parent.as_posix())}",
                stdin=tmp,
            )

    # ── Migration ──────────────────────────────────────────────────────────────

    def _migrate(self, state: InstanceState) -> None:
        remote = self._remote(state)
        print(f"\n» Preparing transactional migration to {state.instance_id}...")
        local_version = self.runner.run(
            ["kirocrew", "--version"], capture=True
        ).stdout.strip()
        remote_version = remote.run(
            "orre", "kirocrew --version", capture=True
        ).stdout.strip()
        if local_version != remote_version:
            raise LauncherError(
                f"Versions differ: local={local_version!r}, remote={remote_version!r}"
            )
        remote_dir = "/home/orre/.local/state/kirocrew-migration"
        rollback_dir = f"{remote_dir}/rollback"
        remote_incoming = ""
        with tempfile.TemporaryDirectory(prefix="kirocrew-migration.") as temp_dir:
            snapshot_dir = Path(temp_dir)
            self.runner.run(["kirocrew", "snapshot", str(snapshot_dir)])
            snapshots = list(snapshot_dir.glob("*.tar.gz"))
            if not snapshots:
                raise LauncherError("No snapshot archive was created")
            snapshot = snapshots[0]
            remote.run(
                "orre",
                f"set -e; umask 077; mkdir -p {shlex.quote(rollback_dir)}; "
                f"chmod 700 {shlex.quote(remote_dir)} {shlex.quote(rollback_dir)}; "
                f"kirocrew snapshot {shlex.quote(rollback_dir)}",
            )
            try:
                remote_incoming = remote.run(
                    "orre",
                    f"set -e; umask 077; mkdir -p {shlex.quote(remote_dir)}; "
                    f"chmod 700 {shlex.quote(remote_dir)}; "
                    f"mktemp {shlex.quote(remote_dir + '/incoming.XXXXXX.tar.gz')}",
                    capture=True,
                ).stdout.strip()
                with snapshot.open("rb") as fh:
                    remote.run(
                        "orre",
                        f"cat > {shlex.quote(remote_incoming)}",
                        stdin=fh,
                    )
                dry = remote.run(
                    "orre",
                    f"kirocrew restore {shlex.quote(remote_incoming)} --mode replace --dry-run --force",
                    check=False,
                )
                if dry.returncode != 0:
                    raise LauncherError("Restore dry-run failed; remote unchanged")
                if not self.arguments.assume_yes:
                    if input("Type 'migrate' to continue: ").strip() != "migrate":
                        print("Aborted.")
                        return
                remote.run(
                    "root",
                    _transactional_restore_script(remote_incoming, rollback_dir),
                )
                remote_incoming = ""
            finally:
                if remote_incoming:
                    remote.run(
                        "orre", f"rm -f {shlex.quote(remote_incoming)}", check=False
                    )
        print("  ✓ Migration committed after health validation")

    # ── Internal helpers ───────────────────────────────────────────────────────

    def _require_bound_state(self) -> InstanceState:
        state = self.saved_state
        if state is None:
            raise LauncherError(f"No managed instance at {self.store.path}")
        state = self.resources.bind_identity(state)
        if not state.instance_id:
            raise LauncherError("No instance ID in saved state")
        self.saved_state = state
        return state

    def _persist(self, state: InstanceState, lifecycle: str) -> InstanceState:
        updated = state.updated(lifecycle=lifecycle)
        self.store.save(updated)
        self.saved_state = updated
        return updated

    def _remote(self, state: InstanceState) -> RemoteHost:
        if not state.instance_id:
            raise LauncherError("Cannot connect without an instance ID")
        return RemoteHost(self.runner, self.aws, state.instance_id, self.key_file)

    def _print_result(self, state: InstanceState, failures: list[str]) -> None:
        print(f"\n✓ Done — instance {state.instance_id} is deployed")
        print(f"  Portal:   {self.script_dir / 'launch-ec2'} portal")
        print(f"            {self.script_dir / 'launch-portal'}")
        print(f"  Connect:  {self.script_dir / 'launch-ec2'} connect")
        print(f"  SSH:      {self.script_dir / 'launch-ec2'} ssh")
        if failures:
            print(f"  ⚠ Failed repos: {', '.join(failures)}")


def _append_previous(
    existing: tuple[PreviousInstance, ...],
    item: PreviousInstance | None,
) -> tuple[PreviousInstance, ...]:
    if item is None:
        return existing
    return (*existing, item)


def _transactional_restore_script(archive: str, rollback_dir: str) -> str:
    """Generate a remote restore script that rolls back on any failure."""
    return f"""set -e
uid=$(id -u orre)
user_systemctl() {{
  sudo -u orre env XDG_RUNTIME_DIR="/run/user/${{uid}}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${{uid}}/bus" systemctl --user "$@"
}}
systemctl start "user@${{uid}}.service"
user_systemctl stop kirocrew.service
rollback() {{
  echo "Restoring rollback snapshot..." >&2
  latest=$(find {shlex.quote(rollback_dir)} -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\\n' | sort -nr | head -n1 | cut -d' ' -f2-)
  if [ -n "$latest" ]; then
    sudo -u orre -H kirocrew restore "$latest" --mode replace --force || true
  fi
  user_systemctl start kirocrew.service || true
}}
trap rollback EXIT
sudo -u orre -H kirocrew restore {shlex.quote(archive)} --mode replace
user_systemctl start kirocrew.service
sleep 2
sudo -u orre -H kirocrew doctor
trap - EXIT
rm -f {shlex.quote(archive)}
"""
