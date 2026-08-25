"""Main coordinator that ties AWS resources, state, and remote host together."""
from __future__ import annotations

import shlex
import shutil
import tempfile
import uuid
from datetime import datetime
from pathlib import Path

from .aws_resources import AwsResources
from .models import (
    DEFAULT_AMI,
    DEFAULT_INSTANCE_TYPE,
    DEFAULT_REGION,
    GITHUB_ED25519_KEY,
    GITLAB_ED25519_KEY,
    KEY_NAME,
    PORTAL_LOCAL_PORT,
    PORTAL_PORT,
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
        if self.arguments.command == "ssh":
            self._open_ssh(state)
            return
        if self.arguments.command == "migrate-kirocrew":
            self._migrate(state)
            return
        if self.arguments.command == "sync-state":
            self._sync_state(state)
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
        if shutil.which("session-manager-plugin") is None:
            raise LauncherError("The AWS Session Manager plugin is required")
        print(f"\n» Opening KiroCrew portal at http://127.0.0.1:{PORTAL_LOCAL_PORT}")
        print("  Keep this command running; press Ctrl+C to close the tunnel.")
        self._remote(state).portal(PORTAL_PORT, PORTAL_LOCAL_PORT)

    def _open_ssh(self, state: InstanceState) -> None:
        remote = self._remote(state)
        print("\n» Opening interactive shell with X11 forwarding...")
        print("  Run 'firefox &' or 'chromium &' to launch browsers.")
        remote.x11_ssh("orre")

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
        self._setup_code_review_graph(remote)
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
        print("\n» Restarting KiroCrew user service...")
        remote.run(
            "root",
            """set -e
uid=$(id -u orre)
systemctl start "user@${uid}.service"
sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user daemon-reload
sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user restart kirocrew.service
sudo -u orre env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user is-active --quiet kirocrew.service
""",
        )
        print("  ✓ KiroCrew service restarted and verified active")

    def _sync_repositories(self, remote: RemoteHost) -> list[str]:
        print("\n» Syncing code repositories...")
        known_hosts = f"{GITLAB_ED25519_KEY}\n{GITHUB_ED25519_KEY}\n"
        # Step 1: set up known_hosts and validate git-ssh-key (needs input_text)
        remote.run(
            "root",
            r"""set -e
sudo -u orre mkdir -p /home/orre/.ssh /home/orre/code/readpeak
cat >> /home/orre/.ssh/known_hosts
sort -u -o /home/orre/.ssh/known_hosts /home/orre/.ssh/known_hosts
chown orre:users /home/orre/.ssh/known_hosts
chmod 600 /home/orre/.ssh/known_hosts
uid=$(id -u orre)
GIT_SSH_KEY="/run/user/${uid}/secrets/git-ssh-key"
if [ ! -f "$GIT_SSH_KEY" ]; then
  echo "git-ssh-key not found at $GIT_SSH_KEY" >&2
  exit 1
fi
""",
            input_text=known_hosts,
        )
        # Step 2: clone/pull repos (no capture — streams output live)
        result = remote.run(
            "root",
            r"""set -e
cd /tmp
uid=$(id -u orre)
runtime_dir="/run/user/${uid}"
GIT_SSH_KEY="${runtime_dir}/secrets/git-ssh-key"
export GIT_SSH_COMMAND="ssh -i ${GIT_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15"
failed=""
for repo in mononode nativeflow cdk renovate-bot eks-workloads; do
  dest="/home/orre/code/readpeak/${repo}"
  if [ ! -d "$dest" ]; then
    echo "  Cloning ${repo}..."
    if ! sudo -u orre -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "git@gitlab.com:readpeak/${repo}.git" "$dest" 2>&1; then
      failed="${failed} ${repo}"
      echo "  ✗ ${repo} (clone failed)"
    else
      echo "  ✓ ${repo} (cloned)"
    fi
  else
    echo "  Pulling ${repo}..."
    if ! sudo -u orre -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git -C "$dest" pull --ff-only --quiet 2>&1; then
      failed="${failed} ${repo}"
      echo "  ✗ ${repo} (pull failed)"
    else
      echo "  ✓ ${repo}"
    fi
  fi
done
pasta=/home/orre/code/pasta
if [ ! -d "$pasta" ]; then
  echo "  Cloning pasta..."
  if ! sudo -u orre -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone git@github.com:orriborri/pasta.git "$pasta" 2>&1; then
    failed="${failed} pasta"
    echo "  ✗ pasta (clone failed)"
  else
    echo "  ✓ pasta (cloned)"
  fi
else
  echo "  Pulling pasta..."
  if ! sudo -u orre -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git -C "$pasta" pull --ff-only --quiet 2>&1; then
    failed="${failed} pasta"
    echo "  ✗ pasta (pull failed)"
  else
    echo "  ✓ pasta"
  fi
fi
if [ -n "$failed" ]; then
  echo "$failed" > /tmp/.repo-sync-failures
  exit 0
fi
rm -f /tmp/.repo-sync-failures
""",
            check=False,
        )
        # Check if there were partial failures
        fail_result = remote.run(
            "root",
            "cat /tmp/.repo-sync-failures 2>/dev/null && rm -f /tmp/.repo-sync-failures || true",
            capture=True,
        )
        failures = fail_result.stdout.strip().split() if fail_result.stdout.strip() else []
        if failures:
            print(f"  ⚠ These repositories failed: {', '.join(failures)}")
        else:
            print("  ✓ All repositories ready")
        return failures

    # ── Code Review Graph ────────────────────────────────────────────────────

    def _setup_code_review_graph(self, remote: RemoteHost) -> None:
        """Install code-review-graph, build graphs for all repos, and start the daemon."""
        print("\n» Setting up code-review-graph...")
        # Install via uv tool (idempotent — upgrades if already present)
        remote.run(
            "root",
            r"""set -e
sudo -u orre -H env PATH="/home/orre/.local/bin:/nix/var/nix/profiles/default/bin:$PATH" \
  uv tool install code-review-graph --upgrade 2>&1 | tail -3
""",
        )
        # Build graph and register with daemon for all git repos under ~/code
        remote.run(
            "root",
            r"""set -e
export PATH="/home/orre/.local/bin:/nix/var/nix/profiles/default/bin:$PATH"
CRG="/home/orre/.local/bin/code-review-graph"
for git_dir in $(find /home/orre/code -maxdepth 3 -name .git -type d 2>/dev/null | sort); do
  repo_dir=$(dirname "$git_dir")
  repo_name=$(basename "$repo_dir")
  echo "  Building graph for ${repo_name}..."
  sudo -u orre -H env PATH="$PATH" "$CRG" install --repo "$repo_dir" --platform kiro --no-hooks --no-instructions -y 2>&1 | tail -2
  sudo -u orre -H env PATH="$PATH" "$CRG" build --repo "$repo_dir" 2>&1 | tail -2
  sudo -u orre -H env PATH="$PATH" "$CRG" daemon add "$repo_dir" --alias "$repo_name" 2>&1 || true
  echo "  ✓ ${repo_name}"
done
echo "  Starting daemon..."
sudo -u orre -H env PATH="$PATH" "$CRG" daemon start 2>&1 | tail -2 || true
""",
            check=False,
        )
        print("  ✓ code-review-graph installed, graphs built, daemon running")

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
        print(f"  Portal: {self.script_dir / 'launch-ec2'} portal")
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
