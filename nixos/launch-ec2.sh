#!/usr/bin/env bash
set -euo pipefail

# Launch (or reuse) a NixOS EC2 instance and bootstrap it with the kirocrew-ec2 flake config.
# All connectivity is via SSM — no security group ingress, no direct SSH.
#
# On first run: creates instance + saves state to .kirocrew-ec2.json
# On subsequent runs: starts existing instance if stopped, then rebuilds.
#
# Usage:
#   ./nixos/launch-ec2.sh [start]                   # launch or resume instance (default)
#   ./nixos/launch-ec2.sh portal                    # open local web portal through SSM
#   ./nixos/launch-ec2.sh stop                      # stop instance
#   ./nixos/launch-ec2.sh destroy                   # terminate instance
#   ./nixos/launch-ec2.sh rebuild                   # skip launch, just rebuild existing
#   ./nixos/launch-ec2.sh new                       # force new instance (ignore saved state)
#   ./nixos/launch-ec2.sh migrate-kirocrew [--yes]  # migrate local KiroCrew state to remote
#
# Defaults are loaded from .kirocrew-ec2.config (next to this script).
# Priority: explicit argument > state file > config file.
#
# Defaults (override in .kirocrew-ec2.config):
#   profile:       (from config, e.g. "Sandbox")
#   region:        eu-central-1
#   instance-type: t4g.xlarge
#   ami-id:        ami-0cdce1c7f7fa96c0d  (NixOS 25.05 arm64)

PROFILE=""

usage() {
  cat <<EOF
Usage: $0 [COMMAND] [profile] [region] [instance-type] [ami-id]

Commands:
  start              Launch or resume the instance and rebuild it (default)
  portal             Start or resume the saved instance and open the web portal
  stop               Stop the saved instance
  destroy            Permanently terminate the saved instance
  rebuild            Rebuild the saved instance
  new                Launch a new instance
  migrate-kirocrew   Migrate local KiroCrew state to the saved instance

Portal URL: http://127.0.0.1:7780 (the tunnel runs until Ctrl+C)
EOF
}

# Parse flags and subcommands
FORCE_NEW=false
REBUILD_ONLY=false
MIGRATE_KIROCREW=false
PORTAL_TUNNEL=false
ASSUME_YES=false
STOP_INSTANCE=false
DESTROY_INSTANCE=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    start)              shift ;;  # default action, no-op
    portal|--portal)   PORTAL_TUNNEL=true; shift ;;
    stop|--stop)       STOP_INSTANCE=true; shift ;;
    destroy|--destroy) DESTROY_INSTANCE=true; shift ;;
    rebuild|--rebuild) REBUILD_ONLY=true; shift ;;
    new|--new)         FORCE_NEW=true; shift ;;
    migrate-kirocrew|--migrate-kirocrew) MIGRATE_KIROCREW=true; shift ;;
    --yes)             ASSUME_YES=true; shift ;;
    help|-h|--help)    usage; exit 0 ;;
    --*)               echo "Unknown flag: $1"; exit 1 ;;
    *)                 POSITIONAL+=("$1"); shift ;;
  esac
done

if [ "$MIGRATE_KIROCREW" = true ] && { [ "$FORCE_NEW" = true ] || [ "$REBUILD_ONLY" = true ] || [ "$PORTAL_TUNNEL" = true ] || [ "$STOP_INSTANCE" = true ] || [ "$DESTROY_INSTANCE" = true ]; }; then
  echo "ERROR: --migrate-kirocrew cannot be combined with --new, --rebuild, --portal, --stop, or --destroy."
  exit 1
fi
if [ "$PORTAL_TUNNEL" = true ] && { [ "$FORCE_NEW" = true ] || [ "$REBUILD_ONLY" = true ] || [ "$STOP_INSTANCE" = true ] || [ "$DESTROY_INSTANCE" = true ]; }; then
  echo "ERROR: --portal cannot be combined with --new, --rebuild, --stop, or --destroy."
  exit 1
fi
if [ "$ASSUME_YES" = true ] && [ "$MIGRATE_KIROCREW" = false ]; then
  echo "ERROR: --yes is only valid with --migrate-kirocrew."
  exit 1
fi

# ── Load config file for defaults ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.kirocrew-ec2.config"
DEFAULT_PROFILE=""
DEFAULT_REGION="eu-central-1"
DEFAULT_INSTANCE_TYPE="t4g.xlarge"
DEFAULT_AMI="ami-0cdce1c7f7fa96c0d"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=.kirocrew-ec2.config
  source "$CONFIG_FILE"
fi

# Positional args: [profile] [region] [instance-type] [ami-id]
PROFILE="${POSITIONAL[0]:-$DEFAULT_PROFILE}"
REGION="${POSITIONAL[1]:-$DEFAULT_REGION}"
INSTANCE_TYPE="${POSITIONAL[2]:-$DEFAULT_INSTANCE_TYPE}"
AMI="${POSITIONAL[3]:-$DEFAULT_AMI}"
KEY_NAME="kirocrew"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
ROLE_NAME="kirocrew-ssm"
FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="${FLAKE_DIR}/nixos/.kirocrew-ec2.json"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

# SSH via SSM ProxyCommand (no direct network access needed)
ssm_ssh() {
  local user="${1:-root}"
  local proxy_command
  shift
  printf -v proxy_command \
    'aws ssm start-session --profile %q --region %q --target %q --document-name AWS-StartSSHSession --parameters portNumber=22' \
    "$PROFILE" "$REGION" "$IID"
  ssh -o StrictHostKeyChecking=accept-new \
      -o "ProxyCommand=$proxy_command" \
      -i "$KEY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes \
      "${user}@${IID}" "$@"
}

# ── Try loading state early (to get profile if not on command line) ───────────
# If no explicit profile was given and a state file exists, prefer the saved profile.
if [ -z "${POSITIONAL[0]:-}" ] && [ -f "$STATE_FILE" ]; then
  SAVED_PROFILE=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('profile',''))" 2>/dev/null || true)
  if [ -n "$SAVED_PROFILE" ]; then
    PROFILE="$SAVED_PROFILE"
  fi
fi
if [ -z "$PROFILE" ]; then
  echo "ERROR: No AWS profile specified, none in config file, and none saved in state file."
  echo "Either pass a profile:  $0 <aws-profile>"
  echo "Or set DEFAULT_PROFILE in $CONFIG_FILE"
  exit 1
fi

# ── Validate AWS credentials ─────────────────────────────────────────────────
echo -n "» Checking AWS credentials ($PROFILE)... "
if ! aws_ sts get-caller-identity --output text >/dev/null 2>&1; then
  echo "FAILED"
  echo "  AWS credentials for profile '$PROFILE' are not valid."
  echo "  Run: aws sso login --profile $PROFILE"
  exit 1
fi
echo "ok"

# ── State file helpers ────────────────────────────────────────────────────────
save_state() {
  cat > "$STATE_FILE" << EOF
{
  "instance_id": "$IID",
  "region": "$REGION",
  "profile": "$PROFILE",
  "key_file": "$KEY_FILE",
  "flake_dir": "$FLAKE_DIR",
  "created": "$(date -Iseconds)"
}
EOF
  echo "  ✓ State saved to $STATE_FILE"
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    IID=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['instance_id'])")
    REGION=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['region'])")
    if [ -z "$PROFILE" ]; then
      PROFILE=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('profile',''))")
    fi
    return 0
  fi
  return 1
}

get_instance_state() {
  local state
  state=$(aws_ ec2 describe-instances --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  ⚠ AWS error checking instance state: $state" >&2
    echo "not-found"
    return
  fi
  if [ -z "$state" ] || [ "$state" = "None" ]; then
    echo "not-found"
  else
    echo "$state"
  fi
}

wait_for_ssm() {
  echo -n "  Waiting for SSM agent"
  for i in $(seq 1 40); do
    local status
    status=$(aws_ ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$IID" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
    if [ "$status" = "Online" ]; then
      echo " ready"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo " TIMEOUT"
  echo "  SSM agent never came online for $IID"
  echo "  Check that the instance profile has AmazonSSMManagedInstanceCore"
  return 1
}

# ── Handle --stop (early exit) ───────────────────────────────────────────────
if [ "$STOP_INSTANCE" = true ]; then
  if ! load_state; then
    echo "ERROR: No saved instance to stop (no state file at $STATE_FILE)"
    exit 1
  fi
  STATE=$(get_instance_state)
  if [ "$STATE" = "stopped" ]; then
    echo "Instance $IID is already stopped."
    exit 0
  fi
  echo "» Stopping instance $IID..."
  aws_ ec2 stop-instances --instance-ids "$IID" --output text --query 'StoppingInstances[0].CurrentState.Name'
  echo "  ✓ Stop initiated. Instance will stop billing for compute shortly."
  echo "  (EBS volume still incurs storage cost. Use --destroy to fully remove.)"
  exit 0
fi

# ── Handle --destroy (full teardown, early exit) ─────────────────────────────
if [ "$DESTROY_INSTANCE" = true ]; then
  if ! load_state; then
    echo "ERROR: No saved instance to destroy (no state file at $STATE_FILE)"
    exit 1
  fi
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ ⚠️  DESTROY: This will permanently terminate the instance and    │"
  echo "│    delete all data on it. This cannot be undone.                │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Instance: $IID"
  echo "│ Region:   $REGION"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo
  read -rp "Type 'destroy' to confirm: " confirm
  if [ "$confirm" != "destroy" ]; then
    echo "Aborted."
    exit 0
  fi
  echo "» Terminating instance $IID..."
  aws_ ec2 terminate-instances --instance-ids "$IID" --output text --query 'TerminatingInstances[0].CurrentState.Name'
  echo "  ✓ Instance terminated"

  rm -f "$STATE_FILE"
  echo "  ✓ State file removed"
  echo
  echo "Done. All AWS resources for this instance are gone."
  echo "(IAM role 'kirocrew-ssm' and key pair 'kirocrew' are retained for future use.)"
  exit 0
fi

# ── Try to reuse existing instance ───────────────────────────────────────────
REUSING=false

if [ "$FORCE_NEW" = false ] && load_state; then
  STATE=$(get_instance_state)
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ KiroCrew NixOS EC2 — reusing existing instance                   │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Instance: $IID"
  echo "│ State:    $STATE"
  echo "│ Region:   $REGION"
  echo "│ Flake:    $FLAKE_DIR"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo

  case "$STATE" in
    running)
      echo "» Instance already running"
      wait_for_ssm
      REUSING=true
      ;;
    stopped)
      echo "» Starting stopped instance $IID..."
      aws_ ec2 start-instances --instance-ids "$IID" >/dev/null
      aws_ ec2 wait instance-running --instance-ids "$IID"
      echo "  ✓ Running"
      wait_for_ssm
      REUSING=true
      ;;
    terminated|shutting-down|not-found)
      echo "» Instance $IID is $STATE — launching a new one"
      rm -f "$STATE_FILE"
      ;;
    *)
      echo "» Instance in state '$STATE' — waiting for it to settle..."
      sleep 15
      STATE=$(get_instance_state)
      if [ "$STATE" = "running" ]; then
        wait_for_ssm
        REUSING=true
      else
        echo "  ⚠ Still $STATE — launching a new instance"
        rm -f "$STATE_FILE"
      fi
      ;;
  esac
fi

# ── Open the web portal through SSM (no rebuild) ─────────────────────────────
if [ "$PORTAL_TUNNEL" = true ]; then
  if [ "$REUSING" = false ]; then
    echo "ERROR: No saved instance found at $STATE_FILE"
    echo "Run '$0 start' once before opening the portal."
    exit 1
  fi
  if ! command -v session-manager-plugin >/dev/null 2>&1; then
    echo "ERROR: The AWS Session Manager plugin is required for port forwarding."
    exit 1
  fi

  echo
  echo "» Opening KiroCrew portal at http://127.0.0.1:7780"
  echo "  Keep this command running; press Ctrl+C to close the tunnel."
  aws_ ssm start-session \
    --target "$IID" \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["7780"],"localPortNumber":["7780"]}'
  exit 0
fi

# ── Launch new instance if needed ────────────────────────────────────────────
if [ "$REUSING" = false ] && [ "$REBUILD_ONLY" = false ] && [ "$MIGRATE_KIROCREW" = false ]; then
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ KiroCrew NixOS EC2 — launch + bootstrap                         │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Profile: $PROFILE"
  echo "│ Region:  $REGION"
  echo "│ Type:    $INSTANCE_TYPE"
  echo "│ AMI:     $AMI"
  echo "│ Flake:   $FLAKE_DIR"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo

  # ── 1. IAM instance profile (idempotent) ─────────────────────────────────
  echo "» Ensuring IAM role + instance profile ($ROLE_NAME)..."
  if ! aws --profile "$PROFILE" iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    aws --profile "$PROFILE" iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws --profile "$PROFILE" iam attach-role-policy --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  fi
  if ! aws --profile "$PROFILE" iam get-instance-profile --instance-profile-name "$ROLE_NAME" &>/dev/null; then
    aws --profile "$PROFILE" iam create-instance-profile --instance-profile-name "$ROLE_NAME"
    aws --profile "$PROFILE" iam add-role-to-instance-profile \
      --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
    echo "  waiting 10s for IAM propagation..."
    sleep 10
  fi
  echo "  ✓ IAM ready"

  # ── 2. Key pair (create if missing) ────────────────────────────────────────
  if [ ! -f "$KEY_FILE" ]; then
    echo "» Creating EC2 key pair ($KEY_NAME)..."
    aws_ ec2 create-key-pair --key-name "$KEY_NAME" \
      --query KeyMaterial --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "  ✓ Key saved to $KEY_FILE"
  else
    echo "» Key $KEY_FILE already exists, reusing"
    if ! aws_ ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
      echo "  ⚠ Key file exists but key pair not in $REGION — import it:"
      echo "    aws ec2 import-key-pair --profile $PROFILE --region $REGION --key-name $KEY_NAME --public-key-material fileb://~/.ssh/${KEY_NAME}.pub"
      exit 1
    fi
  fi

  # ── 3. Get default VPC security group (outbound-only, no ingress) ──────────
  echo "» Using default VPC security group (no ingress rules added)..."
  DEFAULT_VPC=$(aws_ ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
  DEFAULT_SG=$(aws_ ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$DEFAULT_VPC" "Name=group-name,Values=default" \
    --query 'SecurityGroups[0].GroupId' --output text)
  echo "  ✓ VPC $DEFAULT_VPC — SG $DEFAULT_SG (egress-only)"

  # ── 4. Launch instance ─────────────────────────────────────────────────────
  echo "» Launching $INSTANCE_TYPE from $AMI..."
  IID=$(aws_ ec2 run-instances \
    --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$DEFAULT_SG" \
    --iam-instance-profile "Name=$ROLE_NAME" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3","Encrypted":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kirocrew}]" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --query 'Instances[0].InstanceId' --output text)
  echo "  Instance: $IID"
  echo "  Waiting for running state..."
  aws_ ec2 wait instance-running --instance-ids "$IID"
  echo "  ✓ Running"

  # Save state for reuse
  save_state

  # Wait for SSM to come online (first boot takes a bit)
  wait_for_ssm

elif { [ "$REBUILD_ONLY" = true ] || [ "$MIGRATE_KIROCREW" = true ]; } && [ "$REUSING" = false ]; then
  if [ "$MIGRATE_KIROCREW" = true ]; then
    echo "ERROR: --migrate-kirocrew specified but no saved instance found at $STATE_FILE"
  else
    echo "ERROR: --rebuild specified but no saved instance found at $STATE_FILE"
  fi
  exit 1
fi

# ── Migrate KiroCrew state (explicit, reversible operation) ──────────────────
if [ "$MIGRATE_KIROCREW" = true ]; then
  echo
  echo "» Preparing full KiroCrew migration to $IID..."

  LOCAL_VERSION=$(kirocrew --version)
  REMOTE_VERSION=$(ssm_ssh orre 'kirocrew --version')
  if [ "$LOCAL_VERSION" != "$REMOTE_VERSION" ]; then
    echo "ERROR: KiroCrew versions differ."
    echo "  Local:  $LOCAL_VERSION"
    echo "  Remote: $REMOTE_VERSION"
    echo "Upgrade one side so the versions match before migrating."
    exit 1
  fi
  echo "  ✓ Matching versions: $LOCAL_VERSION"

  LOCAL_SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kirocrew-migration.XXXXXX")
  REMOTE_INCOMING=""
  cleanup_migration_artifacts() {
    rm -rf "$LOCAL_SNAPSHOT_DIR"
    if [ -n "$REMOTE_INCOMING" ]; then
      ssm_ssh orre "rm -f '$REMOTE_INCOMING'" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_migration_artifacts EXIT

  echo "» Creating local snapshot..."
  umask 077
  kirocrew snapshot "$LOCAL_SNAPSHOT_DIR"
  LOCAL_SNAPSHOT=$(find "$LOCAL_SNAPSHOT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  if [ -z "$LOCAL_SNAPSHOT" ]; then
    echo "ERROR: KiroCrew did not create a snapshot archive in $LOCAL_SNAPSHOT_DIR"
    exit 1
  fi
  echo "  ✓ Local snapshot created"

  REMOTE_MIGRATION_DIR="/home/orre/.local/state/kirocrew-migration"
  REMOTE_BACKUP_DIR="${REMOTE_MIGRATION_DIR}/rollback"

  echo "» Creating remote rollback snapshot..."
  ssm_ssh orre "set -e; umask 077; mkdir -p '$REMOTE_BACKUP_DIR'; chmod 700 '$REMOTE_MIGRATION_DIR' '$REMOTE_BACKUP_DIR'; kirocrew snapshot '$REMOTE_BACKUP_DIR'"
  echo "  ✓ Rollback snapshot retained at $REMOTE_BACKUP_DIR"

  echo "» Transferring migration snapshot securely..."
  REMOTE_INCOMING=$(ssm_ssh orre "set -e; umask 077; mkdir -p '$REMOTE_MIGRATION_DIR'; chmod 700 '$REMOTE_MIGRATION_DIR'; mktemp '$REMOTE_MIGRATION_DIR/incoming.XXXXXX.tar.gz'")
  ssm_ssh orre "set -e; cat > '$REMOTE_INCOMING'" < "$LOCAL_SNAPSHOT"
  echo "  ✓ Snapshot transferred"

  echo "» Validating restore plan..."
  if ! ssm_ssh orre "kirocrew restore '$REMOTE_INCOMING' --mode replace --dry-run --force"; then
    ssm_ssh orre "rm -f '$REMOTE_INCOMING'"
    echo "ERROR: Restore dry-run failed; remote state was not changed."
    exit 1
  fi

  if [ "$ASSUME_YES" = false ]; then
    echo
    echo "This will replace the remote KiroCrew state on $IID."
    echo "A rollback snapshot is stored remotely at $REMOTE_BACKUP_DIR."
    read -rp "Type 'migrate' to continue: " confirm
    if [ "$confirm" != "migrate" ]; then
      ssm_ssh orre "rm -f '$REMOTE_INCOMING'"
      echo "Aborted. Remote state was not changed."
      exit 0
    fi
  fi

  echo "» Stopping service, restoring state, and validating..."
  if ! ssm_ssh root "
    set -e
    uid=\$(id -u orre)
    user_systemctl() {
      sudo -u orre env \
        XDG_RUNTIME_DIR=\"/run/user/\${uid}\" \
        DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\${uid}/bus\" \
        systemctl --user \"\$@\"
    }
    systemctl start \"user@\${uid}.service\"
    restart_service() {
      user_systemctl start kirocrew.service || true
    }
    user_systemctl stop kirocrew.service
    trap restart_service EXIT
    if sudo -u orre -H kirocrew restore '$REMOTE_INCOMING' --mode replace; then
      user_systemctl start kirocrew.service
      trap - EXIT
      sleep 2
      sudo -u orre -H kirocrew doctor
      rm -f '$REMOTE_INCOMING'
    else
      echo 'Restore failed. The rollback snapshot remains at $REMOTE_BACKUP_DIR.' >&2
      exit 1
    fi
  "; then
    echo "ERROR: Migration failed. The rollback snapshot remains at $REMOTE_BACKUP_DIR."
    exit 1
  fi

  echo
  echo "  ✓ KiroCrew migration complete"
  echo "  ✓ Remote service restarted and doctor passed"
  echo "  ✓ Rollback snapshot retained at $REMOTE_BACKUP_DIR"
  exit 0
fi

# ── 5. Bootstrap: place age key for sops-nix (if not already present) ────────
echo
echo "» Ensuring age decryption key is on the remote..."
AGE_KEY_PRESENT=$(ssm_ssh root \
  'test -f /home/orre/.config/sops/age/keys.txt && echo yes || echo no')

if [ "$AGE_KEY_PRESENT" = "no" ]; then
  echo "  Age key not found on remote — bootstrapping from 1Password..."
  echo "  (Requires 'op' CLI authenticated locally or OP_SERVICE_ACCOUNT_TOKEN set)"
  AGE_KEY=$(op read "op://Readpeak/kirocrew-age/private key" 2>/dev/null || true)
  if [ -z "$AGE_KEY" ]; then
    echo "  ⚠ Could not read age key from 1Password."
    echo "    Falling back to local key at ~/.config/sops/age/keys.txt"
    if [ -f "$HOME/.config/sops/age/keys.txt" ]; then
      AGE_KEY=$(cat "$HOME/.config/sops/age/keys.txt")
    else
      echo "  ERROR: No local age key found either. Cannot bootstrap sops-nix."
      echo "  Place the age key manually on the remote via SSM:"
      echo "    aws ssm start-session --profile $PROFILE --region $REGION --target $IID"
      exit 1
    fi
  fi
  ssm_ssh root bash <<AGEEOF
    mkdir -p /home/orre/.config/sops/age
    cat > /home/orre/.config/sops/age/keys.txt << 'KEYEOF'
${AGE_KEY}
KEYEOF
    chmod 600 /home/orre/.config/sops/age/keys.txt
    chown -R orre:users /home/orre/.config/sops
AGEEOF
  echo "  ✓ Age key placed on remote"
else
  echo "  ✓ Age key already present"
fi

# ── 6. Rebuild the NixOS config ──────────────────────────────────────────────
echo
echo "» Rebuilding NixOS config (builds ON the remote box via SSM)..."
echo

SSM_PROXY="aws ssm start-session --profile $PROFILE --region $REGION --target $IID --document-name AWS-StartSSHSession --parameters portNumber=22"

NIX_SSHOPTS="-i $KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='$SSM_PROXY'" \
  nix run nixpkgs#nixos-rebuild -- switch \
    --flake "${FLAKE_DIR}#kirocrew-ec2" \
    --target-host "root@${IID}" \
    --build-host "root@${IID}"

echo
echo "» Restarting KiroCrew user service..."
ssm_ssh root '
  set -e
  uid=$(id -u orre)
  systemctl start "user@${uid}.service"
  sudo -u orre env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user daemon-reload
  sudo -u orre env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user restart kirocrew.service
  sudo -u orre env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user is-active --quiet kirocrew.service
'

echo
echo "  ✓ NixOS rebuild complete — KiroCrew and SSM are running"

# ── 7. Auto-clone repositories (if not already present) ─────────────────────
echo
echo "» Ensuring code repositories are cloned..."
ssm_ssh root '
  set -e
  uid=$(id -u orre)
  runtime_dir="/run/user/${uid}"

  # Ensure GitLab and GitHub host keys are trusted
  sudo -u orre mkdir -p /home/orre/.ssh
  if ! grep -q "gitlab.com" /home/orre/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 gitlab.com 2>/dev/null >> /home/orre/.ssh/known_hosts
  fi
  if ! grep -q "github.com" /home/orre/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com 2>/dev/null >> /home/orre/.ssh/known_hosts
  fi
  chown orre:users /home/orre/.ssh/known_hosts
  chmod 600 /home/orre/.ssh/known_hosts

  sudo -u orre mkdir -p /home/orre/code/readpeak

  # Use the sops-decrypted SSH key for GitLab
  GIT_SSH_KEY="${runtime_dir}/secrets/git-ssh-key"
  if [ ! -f "$GIT_SSH_KEY" ]; then
    echo "  ⚠ git-ssh-key not found at $GIT_SSH_KEY — is sops-nix.service running?"
    exit 1
  fi

  export GIT_SSH_COMMAND="ssh -i ${GIT_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

  repos="
    mononode
    nativeflow
    cdk
    renovate-bot
    eks-workloads
  "

  for repo in $repos; do
    dest="/home/orre/code/readpeak/${repo}"
    if [ ! -d "$dest" ]; then
      echo "  Cloning $repo..."
      sudo -u orre env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "git@gitlab.com:readpeak/${repo}.git" "$dest" || true
    else
      echo -n "  Pulling $repo... "
      sudo -u orre env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git -C "$dest" pull --ff-only --quiet 2>&1 && echo "✓" || echo "(skipped — not on a tracking branch or conflicts)"
    fi
  done

  # Pasta (GitHub, separate from S3-mounted vault)
  pasta_dest="/home/orre/code/pasta"
  if [ ! -d "$pasta_dest" ]; then
    echo "  Cloning pasta..."
    sudo -u orre env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "git@github.com:orriborri/pasta.git" "$pasta_dest" || true
  else
    echo -n "  Pulling pasta... "
    sudo -u orre env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git -C "$pasta_dest" pull --ff-only --quiet 2>&1 && echo "✓" || echo "(skipped)"
  fi
'

echo
echo "  ✓ All repositories ready"
echo
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ ✓ Done! Connect via:                                            │"
echo "│   aws ssm start-session --profile $PROFILE --region $REGION --target $IID"
echo "│                                                                 │"
echo "│ SSH over SSM:                                                   │"
echo "│   ssh -o ProxyCommand=\"aws ssm start-session --profile $PROFILE --region $REGION --target $IID --document-name AWS-StartSSHSession --parameters portNumber=22\" -i $KEY_FILE root@$IID"
echo "└─────────────────────────────────────────────────────────────────┘"
