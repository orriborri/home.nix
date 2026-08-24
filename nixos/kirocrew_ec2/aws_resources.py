from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path

from .models import (
    KEY_NAME,
    ROLE_NAME,
    SECURITY_GROUP_NAME,
    AwsIdentity,
    InstanceState,
    LauncherError,
    StateStore,
)
from .runtime import AwsCli, CommandRunner

SSM_POLICY_NAME = "AmazonSSMManagedInstanceCore"


class AwsResources:
    """Reconciles AWS identity, IAM, key, network, and EC2 lifecycle invariants."""

    def __init__(
        self,
        runner: CommandRunner,
        aws: AwsCli,
        store: StateStore,
        identity: AwsIdentity,
        key_file: Path,
    ) -> None:
        self.runner = runner
        self.aws = aws
        self.store = store
        self.identity = identity
        self.key_file = key_file

    def bind_identity(self, state: InstanceState) -> InstanceState:
        if state.account_id and state.account_id != self.identity.account_id:
            raise LauncherError(
                f"Saved instance belongs to AWS account {state.account_id}, but profile "
                f"{self.aws.profile!r} resolves to {self.identity.account_id}"
            )
        updated = state.updated(
            account_id=self.identity.account_id,
            caller_arn=self.identity.arn,
            profile=self.aws.profile,
        )
        if updated != state:
            self.store.save(updated)
        return updated

    def ensure_iam(self) -> None:
        policy_arn = (
            f"arn:{self.identity.partition}:iam::aws:policy/{SSM_POLICY_NAME}"
        )
        changed = False
        print(f"» Reconciling IAM role and instance profile ({ROLE_NAME})...")

        role = self.aws.run_global(
            "iam", "get-role", "--role-name", ROLE_NAME, capture=True, check=False
        )
        if self.aws.is_missing(role, "NoSuchEntity"):
            self.aws.run_global(
                "iam",
                "create-role",
                "--role-name",
                ROLE_NAME,
                "--assume-role-policy-document",
                '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}',
            )
            changed = True
        else:
            self.aws.require_success(role, "get IAM role")

        attached = self.aws.json(
            "iam",
            "list-attached-role-policies",
            "--role-name",
            ROLE_NAME,
            "--query",
            "AttachedPolicies[].PolicyArn",
        )
        if not isinstance(attached, list) or not all(
            isinstance(item, str) for item in attached
        ):
            raise LauncherError("IAM attached-policy response has an invalid shape")
        if policy_arn not in attached:
            self.aws.run_global(
                "iam",
                "attach-role-policy",
                "--role-name",
                ROLE_NAME,
                "--policy-arn",
                policy_arn,
            )
            changed = True

        profile = self.aws.run_global(
            "iam",
            "get-instance-profile",
            "--instance-profile-name",
            ROLE_NAME,
            capture=True,
            check=False,
        )
        if self.aws.is_missing(profile, "NoSuchEntity"):
            self.aws.run_global(
                "iam",
                "create-instance-profile",
                "--instance-profile-name",
                ROLE_NAME,
            )
            roles: list[str] = []
            changed = True
        else:
            self.aws.require_success(profile, "get IAM instance profile")
            try:
                profile_data = json.loads(profile.stdout)
                roles = [
                    role["RoleName"]
                    for role in profile_data["InstanceProfile"]["Roles"]
                ]
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                raise LauncherError("IAM instance-profile response is invalid") from error

        if ROLE_NAME not in roles:
            self.aws.run_global(
                "iam",
                "add-role-to-instance-profile",
                "--instance-profile-name",
                ROLE_NAME,
                "--role-name",
                ROLE_NAME,
            )
            changed = True

        if changed:
            print("  Waiting 10 seconds for IAM propagation...")
            time.sleep(10)
        print("  ✓ IAM role, policy, and instance-profile membership verified")

    def ensure_key_pair(self) -> tuple[str, str]:
        existing = self._describe_key_pair()
        if self.key_file.exists():
            if existing is None:
                raise LauncherError(
                    f"{self.key_file} exists but EC2 key pair {KEY_NAME!r} is absent in {self.aws.region}"
                )
            key_id, aws_fingerprint = existing
            local_fingerprint = self._local_rsa_fingerprint()
            if local_fingerprint.lower() != aws_fingerprint.lower():
                raise LauncherError(
                    f"Local private key {self.key_file} does not match EC2 key pair "
                    f"{KEY_NAME!r}: local={local_fingerprint}, aws={aws_fingerprint}"
                )
            print(f"» Verified EC2 key pair {KEY_NAME} against {self.key_file}")
            return key_id, aws_fingerprint

        if existing is not None:
            raise LauncherError(
                f"EC2 key pair {KEY_NAME!r} exists, but private key {self.key_file} is missing; "
                "EC2 cannot recover private key material"
            )

        print(f"» Creating EC2 key pair ({KEY_NAME})...")
        created = self.aws.json(
            "ec2",
            "create-key-pair",
            "--key-name",
            KEY_NAME,
            "--key-type",
            "rsa",
        )
        if not isinstance(created, dict):
            raise LauncherError("create-key-pair returned an invalid response")
        try:
            key_material = created["KeyMaterial"]
            key_id = created["KeyPairId"]
            fingerprint = created["KeyFingerprint"]
        except KeyError as error:
            raise LauncherError("create-key-pair response is missing key data") from error
        if not all(isinstance(value, str) for value in (key_material, key_id, fingerprint)):
            raise LauncherError("create-key-pair key data must be strings")
        self._write_private_key(key_material)
        local_fingerprint = self._local_rsa_fingerprint()
        if local_fingerprint.lower() != fingerprint.lower():
            self.key_file.unlink(missing_ok=True)
            raise LauncherError("Created private key fingerprint did not match AWS")
        print(f"  ✓ Key saved securely to {self.key_file}")
        return key_id, fingerprint

    def ensure_security_group(self) -> str:
        vpc_id = self.aws.text(
            "ec2",
            "describe-vpcs",
            "--filters",
            "Name=isDefault,Values=true",
            "--query",
            "Vpcs[0].VpcId",
            "--output",
            "text",
        )
        if not vpc_id or vpc_id == "None":
            raise LauncherError(f"No default VPC found in {self.aws.region}")

        groups = self.aws.json(
            "ec2",
            "describe-security-groups",
            "--filters",
            f"Name=vpc-id,Values={vpc_id}",
            f"Name=group-name,Values={SECURITY_GROUP_NAME}",
            "--query",
            "SecurityGroups",
        )
        if not isinstance(groups, list):
            raise LauncherError("describe-security-groups returned an invalid response")
        if len(groups) > 1:
            raise LauncherError(
                f"Multiple {SECURITY_GROUP_NAME!r} security groups exist in {vpc_id}"
            )
        if groups:
            group = groups[0]
            if not isinstance(group, dict) or not isinstance(group.get("GroupId"), str):
                raise LauncherError("security-group response is missing GroupId")
            group_id = group["GroupId"]
        else:
            group_id = self.aws.text(
                "ec2",
                "create-security-group",
                "--group-name",
                SECURITY_GROUP_NAME,
                "--description",
                "KiroCrew SSM-only access; intentionally no ingress",
                "--vpc-id",
                vpc_id,
                "--tag-specifications",
                "ResourceType=security-group,Tags=[{Key=Name,Value=kirocrew-ssm},{Key=ManagedBy,Value=launch-ec2}]",
                "--query",
                "GroupId",
                "--output",
                "text",
            )

        ingress = self.aws.json(
            "ec2",
            "describe-security-groups",
            "--group-ids",
            group_id,
            "--query",
            "SecurityGroups[0].IpPermissions",
        )
        if not isinstance(ingress, list):
            raise LauncherError("security-group ingress response is invalid")
        if ingress:
            self.aws.run(
                "ec2",
                "revoke-security-group-ingress",
                "--group-id",
                group_id,
                "--ip-permissions",
                json.dumps(ingress, separators=(",", ":")),
            )

        verified = self.aws.json(
            "ec2",
            "describe-security-groups",
            "--group-ids",
            group_id,
            "--query",
            "SecurityGroups[0].IpPermissions",
        )
        if verified != []:
            raise LauncherError(f"Security group {group_id} still has ingress rules")
        print(f"  ✓ Security group {group_id} has no ingress rules")
        return group_id

    def attach_security_group(self, instance_id: str, group_id: str) -> None:
        current = self.aws.json(
            "ec2",
            "describe-instances",
            "--instance-ids",
            instance_id,
            "--query",
            "Reservations[0].Instances[0].SecurityGroups[].GroupId",
        )
        if current == [group_id]:
            return
        self.aws.run(
            "ec2",
            "modify-instance-attribute",
            "--instance-id",
            instance_id,
            "--groups",
            group_id,
        )
        print(f"  ✓ Attached SSM-only security group {group_id}")

    def recover_or_launch(self, state: InstanceState) -> InstanceState:
        if state.instance_id:
            return state
        if not state.client_token:
            raise LauncherError("Pending launch state has no EC2 client token")

        matches = self.aws.json(
            "ec2",
            "describe-instances",
            "--filters",
            f"Name=tag:KiroCrewLaunchToken,Values={state.client_token}",
            "Name=instance-state-name,Values=pending,running,stopping,stopped",
            "--query",
            "Reservations[].Instances[].InstanceId",
        )
        if not isinstance(matches, list) or not all(
            isinstance(item, str) for item in matches
        ):
            raise LauncherError("pending-launch lookup returned an invalid response")
        if len(matches) > 1:
            raise LauncherError(
                f"Client token {state.client_token} matched multiple EC2 instances"
            )
        if matches:
            instance_id = matches[0]
        else:
            instance_id = self._run_instances(state)

        updated = state.updated(instance_id=instance_id, lifecycle="provisioning")
        self.store.save(updated)
        return updated

    def finish_launch(self, state: InstanceState) -> InstanceState:
        if not state.instance_id:
            raise LauncherError("Cannot finish launch without an instance ID")
        self.aws.run(
            "ec2", "wait", "instance-running", "--instance-ids", state.instance_id
        )
        updated = state.updated(lifecycle="running")
        self.store.save(updated)
        return updated

    def instance_state(self, instance_id: str) -> str:
        result = self.aws.run(
            "ec2",
            "describe-instances",
            "--instance-ids",
            instance_id,
            "--query",
            "Reservations[0].Instances[0].State.Name",
            "--output",
            "text",
            capture=True,
            check=False,
        )
        self.aws.require_success(result, f"check state for {instance_id}")
        state = result.stdout.strip()
        return "not-found" if not state or state == "None" else state

    def wait_for_ssm(self, instance_id: str) -> None:
        print("  Waiting for SSM agent", end="", flush=True)
        for _ in range(40):
            result = self.aws.run(
                "ssm",
                "describe-instance-information",
                "--filters",
                f"Key=InstanceIds,Values={instance_id}",
                "--query",
                "InstanceInformationList[0].PingStatus",
                "--output",
                "text",
                capture=True,
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip() == "Online":
                print(" ready")
                return
            print(".", end="", flush=True)
            time.sleep(5)
        print(" TIMEOUT")
        raise LauncherError(f"SSM agent never came online for {instance_id}")

    def _run_instances(self, state: InstanceState) -> str:
        required = {
            "ami": state.ami,
            "instance_type": state.instance_type,
            "security_group_id": state.security_group_id,
            "client_token": state.client_token,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise LauncherError(f"Pending launch is missing: {', '.join(missing)}")
        return self.aws.text(
            "ec2",
            "run-instances",
            "--image-id",
            state.ami,
            "--instance-type",
            state.instance_type,
            "--key-name",
            KEY_NAME,
            "--security-group-ids",
            state.security_group_id,
            "--iam-instance-profile",
            f"Name={ROLE_NAME}",
            "--client-token",
            state.client_token,
            "--block-device-mappings",
            '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3","Encrypted":true}}]',
            "--tag-specifications",
            f"ResourceType=instance,Tags=[{{Key=Name,Value=kirocrew}},{{Key=ManagedBy,Value=launch-ec2}},{{Key=KiroCrewLaunchToken,Value={state.client_token}}}]",
            "--metadata-options",
            "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled",
            "--query",
            "Instances[0].InstanceId",
            "--output",
            "text",
        )

    def _describe_key_pair(self) -> tuple[str, str] | None:
        result = self.aws.run(
            "ec2",
            "describe-key-pairs",
            "--key-names",
            KEY_NAME,
            "--output",
            "json",
            capture=True,
            check=False,
        )
        if self.aws.is_missing(result, "InvalidKeyPair.NotFound"):
            return None
        self.aws.require_success(result, "describe EC2 key pair")
        try:
            data = json.loads(result.stdout)["KeyPairs"][0]
            key_id = data["KeyPairId"]
            fingerprint = data["KeyFingerprint"]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
            raise LauncherError("describe-key-pairs response is invalid") from error
        if not isinstance(key_id, str) or not isinstance(fingerprint, str):
            raise LauncherError("EC2 key-pair identifiers must be strings")
        return key_id, fingerprint

    def _local_rsa_fingerprint(self) -> str:
        result = self.runner.run_bytes(
            [
                "openssl",
                "pkcs8",
                "-in",
                str(self.key_file),
                "-inform",
                "PEM",
                "-outform",
                "DER",
                "-topk8",
                "-nocrypt",
            ],
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.decode(errors="replace").strip()
            raise LauncherError(f"Could not fingerprint {self.key_file}: {detail}")
        digest = hashlib.sha1(result.stdout, usedforsecurity=False).hexdigest()
        return ":".join(digest[index : index + 2] for index in range(0, len(digest), 2))

    def _write_private_key(self, key_material: str) -> None:
        self.key_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.key_file.parent.chmod(0o700)
        try:
            descriptor = os.open(
                self.key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
            )
            with os.fdopen(descriptor, "w") as stream:
                stream.write(key_material.rstrip("\n") + "\n")
                stream.flush()
                os.fsync(stream.fileno())
        except OSError as error:
            self.key_file.unlink(missing_ok=True)
            raise LauncherError(
                f"EC2 key pair was created, but private key could not be secured at "
                f"{self.key_file}: {error}"
            ) from error
