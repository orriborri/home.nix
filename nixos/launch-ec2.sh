#!/usr/bin/env bash
set -euo pipefail

# Launch (or reuse) a NixOS EC2 instance and bootstrap it with the kirocrew-ec2 flake config.
# After bootstrap the SSM agent is running; SSH ingress is revoked and all future
# access goes through SSM (shell, SSH-over-SSM, port-forward).
#
# On first run: creates instance + saves state to .kirocrew-ec2.json
# On subsequent runs: starts existing instance if stopped, then rebuilds.
#
# Usage:
#   ./nixos/launch-ec2.sh <aws-profile> [region] [instance-type] [ami-id]
#   ./nixos/launch-ec2.sh <aws-profile> --rebuild   # skip launch, just rebuild existing
#   ./nixos/launch-ec2.sh --stop                    # stop instance (profile from state file)
#   ./nixos/launch-ec2.sh --destroy                 # terminate instance
#   ./nixos/launch-ec2.sh --rebuild                 # rebuild (profile from state file)
#   ./nixos/launch-ec2.sh <aws-profile> --new       # force new instance (ignore saved state)
#
# Profile is optional when a state file exists (saved from a previous run).
#
# Defaults:
#   region:        eu-central-1
#   instance-type: t4g.xlarge
#   ami-id:        ami-0cdce1c7f7fa96c0d  (NixOS 25.05 arm64)

PROFILE=""

# Parse flags (can appear anywhere before positional args)
FORCE_NEW=false
REBUILD_ONLY=false
STOP_INSTANCE=false
DESTROY_INSTANCE=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    --rebuild) REBUILD_ONLY=true; shift ;;
    --stop) STOP_INSTANCE=true; shift ;;
    --destroy) DESTROY_INSTANCE=true; shift ;;
    --*) echo "Unknown flag: $1"; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# Positional args: [profile] [region] [instance-type] [ami-id]
PROFILE="${POSITIONAL[0]:-}"
REGION="${POSITIONAL[1]:-eu-central-1}"
INSTANCE_TYPE="${POSITIONAL[2]:-t4g.xlarge}"
AMI="${POSITIONAL[3]:-ami-0cdce1c7f7fa96c0d}"
KEY_NAME="kirocrew"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
ROLE_NAME="kirocrew-ssm"
FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="${FLAKE_DIR}/nixos/.kirocrew-ec2.json"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

# ── Try loading state early (to get profile if not on command line) ───────────
if [ -z "$PROFILE" ] && [ -f "$STATE_FILE" ]; then
  PROFILE=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('profile',''))" 2>/dev/null || true)
fi
if [ -z "$PROFILE" ]; then
  echo "ERROR: No AWS profile specified and none saved in state file."
  echo "Usage: $0 [aws-profile] [--rebuild|--stop|--destroy|--new]"
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
  "security_group": "${SG:-}",
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
    SG=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('security_group',''))")
    REGION=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['region'])")
    # Load profile from state if not provided on command line
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
  # describe-instances returns "None" for terminated instances in some regions
  if [ -z "$state" ] || [ "$state" = "None" ]; then
    echo "not-found"
  else
    echo "$state"
  fi
}

get_instance_ip() {
  aws_ ec2 describe-instances --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

# ── Try to reuse existing instance ───────────────────────────────────────────
REUSING=false

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

  # Clean up security group if we created one
  if [ -n "${SG:-}" ]; then
    echo "» Deleting security group $SG..."
    sleep 5  # wait for instance to start terminating before SG can be deleted
    aws_ ec2 delete-security-group --group-id "$SG" 2>/dev/null && echo "  ✓ SG deleted" || echo "  ⚠ SG deletion failed (may still have dependencies — delete manually later)"
  fi

  # Remove state file
  rm -f "$STATE_FILE"
  echo "  ✓ State file removed"
  echo
  echo "Done. All AWS resources for this instance are gone."
  echo "(IAM role 'kirocrew-ssm' and key pair 'kirocrew' are retained for future use.)"
  exit 0
fi

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
      IP=$(get_instance_ip)
      echo "  ✓ IP: $IP"
      REUSING=true
      ;;
    stopped)
      echo "» Starting stopped instance $IID..."
      aws_ ec2 start-instances --instance-ids "$IID" >/dev/null
      aws_ ec2 wait instance-running --instance-ids "$IID"
      IP=$(get_instance_ip)
      echo "  ✓ Running at $IP"
      echo -n "  Waiting for SSH"
      for i in $(seq 1 30); do
        if ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
             -o ConnectTimeout=3 -o BatchMode=yes root@"$IP" true 2>/dev/null; then
          break
        fi
        echo -n "."
        sleep 5
        if [ "$i" -eq 30 ]; then
          echo " TIMEOUT"
          echo "  SSH not reachable — retry with: $0 $PROFILE --rebuild"
          exit 1
        fi
      done
      echo " ready"
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
        IP=$(get_instance_ip)
        REUSING=true
      else
        echo "  ⚠ Still $STATE — launching a new instance"
        rm -f "$STATE_FILE"
      fi
      ;;
  esac
fi

# ── Launch new instance if needed ────────────────────────────────────────────
if [ "$REUSING" = false ] && [ "$REBUILD_ONLY" = false ]; then
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

  # ── 3. Security group with temporary SSH ingress ───────────────────────────
  echo "» Creating security group with temporary SSH ingress..."
  MYIP=$(curl -s https://checkip.amazonaws.com)
  SG=$(aws_ ec2 create-security-group \
    --group-name "kirocrew-bootstrap-$(date +%s)" \
    --description "Temp SSH for NixOS bootstrap - delete after first rebuild" \
    --query GroupId --output text)
  aws_ ec2 authorize-security-group-ingress \
    --group-id "$SG" --protocol tcp --port 22 --cidr "${MYIP}/32"
  echo "  ✓ SG $SG — SSH from $MYIP/32"

  # ── 4. Launch instance ─────────────────────────────────────────────────────
  echo "» Launching $INSTANCE_TYPE from $AMI..."
  IID=$(aws_ ec2 run-instances \
    --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG" \
    --iam-instance-profile "Name=$ROLE_NAME" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3","Encrypted":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kirocrew}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "  Instance: $IID"
  echo "  Waiting for running state..."
  aws_ ec2 wait instance-running --instance-ids "$IID"
  IP=$(aws_ ec2 describe-instances --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "  ✓ Running at $IP"

  # Save state for reuse
  save_state

elif [ "$REBUILD_ONLY" = true ] && [ "$REUSING" = false ]; then
  echo "ERROR: --rebuild specified but no saved instance found at $STATE_FILE"
  exit 1
fi

# ── 5. Bootstrap: place age key for sops-nix (if not already present) ────────
echo
echo "» Ensuring age decryption key is on the remote..."
AGE_KEY_PRESENT=$(ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes root@"$IP" \
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
      echo "  Place the age key manually on the remote:"
      echo "    ssh root@$IP 'sudo -u orre mkdir -p /home/orre/.config/sops/age && ...'"
      echo "  Or store it in 1Password at: op://Readpeak/kirocrew-age/private key"
      exit 1
    fi
  fi
  ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes root@"$IP" bash <<AGEEOF
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
echo "» Rebuilding NixOS config (builds ON the remote box)..."
echo

if [ "$REUSING" = true ]; then
  # Existing instance — direct SSH (SSM ProxyCommand doesn't work with nix-copy-closure)
  echo "  Rebuilding via SSH to $IP"
  NIX_SSHOPTS="-i $KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
    nix run nixpkgs#nixos-rebuild -- switch \
      --flake "${FLAKE_DIR}#kirocrew-ec2" \
      --target-host "root@$IP" \
      --build-host "root@$IP"
else
  # Fresh instance — wait for SSH to come up first
  echo "  Using direct SSH (first-time bootstrap)"
  echo -n "  Waiting for SSH to come up"
  for i in $(seq 1 30); do
    if ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
         -o BatchMode=yes root@"$IP" true 2>/dev/null; then
      break
    fi
    echo -n "."
    sleep 5
    if [ "$i" -eq 30 ]; then
      echo " TIMEOUT -- SSH never became reachable at $IP:22"
      echo "  (Instance $IID is saved -- retry with: $0 $PROFILE --rebuild)"
      exit 1
    fi
  done
  echo " ready"
  ssh-keyscan -H "$IP" >> ~/.ssh/known_hosts 2>/dev/null || true
  NIX_SSHOPTS="-i $KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
    nix run nixpkgs#nixos-rebuild -- switch \
      --flake "${FLAKE_DIR}#kirocrew-ec2" \
      --target-host "root@$IP" \
      --build-host "root@$IP"
fi

echo
echo "» Restarting KiroCrew user service..."
ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes root@"$IP" '
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

# ── 8. Auto-clone repositories (if not already present) ─────────────────────
echo
echo "» Ensuring code repositories are cloned..."
ssh -i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes root@"$IP" '
    set -e
    sudo -u orre mkdir -p /home/orre/code/readpeak

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
        sudo -u orre git clone "git@gitlab.com:readpeak/${repo}.git" "$dest"
      else
        echo "  ✓ $repo already present"
      fi
    done
  '

echo
echo "  ✓ All repositories ready"
