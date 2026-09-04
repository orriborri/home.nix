"""Main coordinator that ties AWS resources, state, and remote host together."""
from __future__ import annotations

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
from .models import (
    DEFAULT_AMI,
    DEFAULT_INSTANCE_TYPE,
    DEFAULT_REGION,
    AUTH_SERVER_URLS,
    KEY_NAME,
    LEGACY_CODE_DIRS,
    LOCAL_1P_AGENT_SOCKET,
    LOCAL_MCP_AUTH_DIR,
    PORTAL_LOCAL_PORT,
    PORTAL_PORT,
    REMOTE_AGENT_SOCKET,
    REMOTE_CODE_DIR,
    REMOTE_KIROCREW_HOME,
    REMOTE_MCP_AUTH_DIR,
    REMOTE_VAULT_DIR,
    TTYD_PORT,
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
        if self.arguments.command == "connect":
            self._open_ssm_session(state)
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
            tailscale_ip = remote.tailscale_ip()
            if tailscale_ip and self._tailscale_reachable(tailscale_ip):
                url = f"http://{tailscale_ip}:{PORTAL_PORT}"
                print(f"\n» KiroCrew portal: {url}")
                print("  (via Tailscale — no tunnel needed)")
                self._open_browser(url)
                if agent_forward is not None:
                    print(
                        "  Agent git-push enabled while this stays open; "
                        "press Ctrl+C to close."
                    )
                    try:
                        agent_forward.wait()
                    except KeyboardInterrupt:
                        pass
                return
            # Fallback: SSM port-forward tunnel
            if shutil.which("session-manager-plugin") is None:
                raise LauncherError("The AWS Session Manager plugin is required")
            print(f"\n» Opening KiroCrew portal at http://127.0.0.1:{PORTAL_LOCAL_PORT}")
            if tailscale_ip:
                print("  Tailscale IP found but not reachable locally; using SSM tunnel.")
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
        backoff = 2
        max_backoff = 30
        while True:
            started = time.monotonic()
            try:
                remote.portal(PORTAL_PORT, PORTAL_LOCAL_PORT)
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
                    f"  Portal disconnected; reconnecting in {backoff}s "
                    "(Ctrl+C to stop)..."
                )
                time.sleep(backoff)
            except KeyboardInterrupt:
                raise
            backoff = min(backoff * 2, max_backoff)

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

    @staticmethod
    def _open_browser(url: str) -> None:
        """Open the URL in the default browser, or print it if that fails."""
        import webbrowser

        if not webbrowser.open(url):
            print(f"  Open this URL in your browser: {url}")

    @staticmethod
    def _tailscale_reachable(ip: str) -> bool:
        """Check if the portal port is reachable on a Tailscale IP."""
        import socket

        try:
            with socket.create_connection((ip, int(PORTAL_PORT)), timeout=3):
                return True
        except (OSError, TimeoutError):
            return False

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
        self._print_result(state, failures, remote)

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
        # Install the validated version used by the declarative service.
        # `uv` is provided by the operator's Home Manager profile, so include
        # its per-user profile bin on PATH alongside the Nix/default locations.
        remote.run(
            "root",
            r"""set -e
sudo -u orre -H env PATH="/home/orre/.local/bin:/etc/profiles/per-user/orre/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:$PATH" \
  uv tool install code-review-graph==2.3.8 2>&1 | tail -3
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
        workspace = "/var/lib/kirocrew/.kiro/crew/workspace"
        config = "/var/lib/kirocrew/config.json"
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
with open(config_path) as fh:
    data = json.load(fh)
agent = data.setdefault("agent", {{}})
roots = agent.setdefault("subagent_cwd_allowed_roots", [])
changed = False
for root in (code_dir, vault_dir):
    if root not in roots:
        roots.append(root)
        changed = True
if changed:
    with open(config_path, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\\n")
    print("  ✓ updated subagent_cwd_allowed_roots")
else:
    print("  ✓ subagent_cwd_allowed_roots already current")
PY
KC
"""
        remote.run("root", script, check=False)
        print("  ✓ project directories registered")

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
        """Run an MCP OAuth flow locally and install the token on the gateway.

        The browser OAuth runs on the workstation (mcp-remote writes a cached
        token into LOCAL_MCP_AUTH_DIR). Only the actual credential file — not
        the code_verifier or client_info files — is copied to the gateway's
        REMOTE_MCP_AUTH_DIR over SSM, then the gateway is restarted so the MCP
        server picks up the cached token.
        """
        target = self.arguments.auth_target
        server_url = AUTH_SERVER_URLS.get(target or "")
        if server_url is None:
            raise LauncherError(f"Unknown auth target: {target!r}")

        if shutil.which("npx") is None:
            raise LauncherError("npx is required to run the mcp-remote OAuth flow")

        auth_dir = Path(os.path.expanduser(LOCAL_MCP_AUTH_DIR))
        before = self._mcp_token_files(auth_dir)

        print(f"\n» Starting {target} OAuth in your browser...")
        print("  Complete the login/consent, then return here.")
        print("  Press Ctrl+C once the tools connect (the flow stays open).")
        try:
            self.runner.run(
                ["npx", "-y", "mcp-remote", server_url],
                check=False,
            )
        except KeyboardInterrupt:
            pass

        after = self._mcp_token_files(auth_dir)
        token_file = self._select_token_file(after, before)
        if token_file is None:
            raise LauncherError(
                f"No new token file appeared in {auth_dir}; OAuth did not complete"
            )
        print(f"  ✓ Local token cached: {token_file.name}")

        remote = self._remote(state)
        remote_path = f"{REMOTE_MCP_AUTH_DIR}/{token_file.name}"
        print("\n» Installing the token on the gateway...")
        with token_file.open("rb") as handle:
            remote.run(
                "root",
                "set -e; "
                f"install -d -m 700 -o kirocrew -g kirocrew {shlex.quote(REMOTE_MCP_AUTH_DIR)}; "
                f"install -m 600 -o kirocrew -g kirocrew /dev/stdin {shlex.quote(remote_path)}",
                stdin=handle,
            )
        print(f"  ✓ Installed {remote_path}")

        print("\n» Restarting the gateway to pick up the token...")
        remote.run(
            "root",
            "set -e; systemctl restart kirocrew-gateway.service; "
            "systemctl is-active --quiet kirocrew-gateway.service",
        )
        print(f"  ✓ Gateway restarted; {target} tools should now connect")

    @staticmethod
    def _mcp_token_files(auth_dir: Path) -> dict[str, float]:
        """Map candidate token filenames to their mtimes.

        Only the real credential is a candidate: mcp-remote writes companion
        code_verifier and client_info files that are not the token itself.
        """
        if not auth_dir.is_dir():
            return {}
        candidates: dict[str, float] = {}
        for entry in auth_dir.iterdir():
            if not entry.is_file():
                continue
            name = entry.name
            if "code_verifier" in name or "client_info" in name:
                continue
            candidates[name] = entry.stat().st_mtime
        return candidates

    @staticmethod
    def _select_token_file(
        after: dict[str, float], before: dict[str, float]
    ) -> Path | None:
        """Pick the token file created or refreshed by this OAuth run."""
        auth_dir = Path(os.path.expanduser(LOCAL_MCP_AUTH_DIR))
        changed = [
            name
            for name, mtime in after.items()
            if name not in before or mtime > before[name]
        ]
        if not changed:
            return None
        newest = max(changed, key=lambda name: after[name])
        return auth_dir / newest

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

    def _print_result(self, state: InstanceState, failures: list[str], remote: RemoteHost) -> None:
        print(f"\n✓ Done — instance {state.instance_id} is deployed")
        tailscale_ip = remote.tailscale_ip()
        if tailscale_ip and self._tailscale_reachable(tailscale_ip):
            print(f"  Portal:   http://{tailscale_ip}:{PORTAL_PORT}  (Tailscale)")
            print(f"  Terminal: http://{tailscale_ip}:{TTYD_PORT}  (Zellij web)")
        else:
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
