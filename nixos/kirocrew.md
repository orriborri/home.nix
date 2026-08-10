# KiroCrew NixOS VM

Runs the KiroCrew gateway as a pinned OCI container (`0.1.3`) on NixOS, with
this repo's `./home.nix` toolset via home-manager, SSH, a firewall that opens
only 22, and the dashboard reachable solely through an SSH tunnel.

**Strategy: local QEMU VM first, then reuse the same modules for an EC2 AMI.**

Files (in this repo):
- `flake.nix` → `nixosConfigurations.kirocrew` (+ `nixosModules.kirocrew`)
- `nixos/kirocrew-host.nix` — host: user, ssh, firewall, docker, QEMU vm profile
- `nixos/kirocrew.nix` — the OCI container (loopback publish + seccomp)
- `nixos/seccomp/kirocrew-seccomp.json`
- reuses `./home.nix` for the user environment (same specialArgs as `mkHome`)

## Build & run the local VM

```bash
cd ~/.config/home-manager
nix flake update
nixos-rebuild build-vm --flake .#kirocrew    # → ./result/bin/run-kirocrew-vm
./result/bin/run-kirocrew-vm                  # headless serial console
```

First boot pulls `ghcr.io/kirodotdev/kirocrew:0.1.3` (VM has NAT internet); the
container starts automatically.

> No `nixos-rebuild` on the host? Build via the flake attr:
> `nix build .#nixosConfigurations.kirocrew.config.system.build.vm && ./result/bin/run-*-vm`

## Log in + tunnel

```bash
# SSH in (password: kirocrew — local VM only), host fwd 2222 → guest 22
ssh -p 2222 orre@127.0.0.1
docker exec -it kirocrew kiro-cli login       # device flow, persists in volume
docker exec kirocrew kirocrew token --ttl 2h  # mint dashboard link
```

From your laptop, open a tunnel and browse:

```bash
ssh -p 2222 -NL 5476:localhost:5476 orre@127.0.0.1
# open http://localhost:5476/?token=...  (links expire in minutes)
```

The tunnel endpoint `localhost:5476` is resolved inside the VM by sshd, hitting
the container's guest-loopback publish — same access model you'll use on EC2.

## Known caveats

- **Eval-time host detection.** `home.nix` computes `isNixOS`/`isSilverblue`
  from `builtins.pathExists /etc/NIXOS` and `/run/ostree-booted`. These evaluate
  on the *build* host (your Silverblue box), not the VM, so the VM's home config
  may inherit Silverblue-flavored branches (e.g. `targets.genericLinux.enable`).
  Harmless in most cases; if it bites, thread an `isNixOS` flag via `specialArgs`
  instead of `pathExists`.
- **GUI packages.** `home.nix` pulls some desktop apps (emote, Kiro IDE, fonts)
  that are dead weight on a headless VM. Trim later with a slim profile if the
  closure size matters.
- **Not evaluated here.** These files were authored but `nix` build/eval was not
  run in this environment — treat the first `build-vm` as the real test.

## EC2 AMI

Implemented as `packages.x86_64-linux.kirocrew-ami` (nixos-generators `amazon`
format), reusing `nixos/kirocrew.nix` + `./home.nix` with an EC2-specific host
`nixos/kirocrew-ec2.nix` (key-only SSH; the amazon profile supplies the
bootloader, a growable root fs, `ec2.hvm`, and amazon-init key injection).

**Before building:** add your public key to
`users.users.orre.openssh.authorizedKeys.keys` in `nixos/kirocrew-ec2.nix`
(or SSH in as root via the launch key-pair and add it after first boot).

```bash
cd ~/.config/home-manager
nix flake update
nix build .#packages.x86_64-linux.kirocrew-ami   # → ./result/*.vhd (+ nix-support/image-info.json)
```

Upload + register the AMI (needs an S3 bucket and the `vmimport` service role
in the same region):

```bash
IMG=$(ls result/*.vhd)
aws s3 cp "$IMG" s3://<your-bucket>/kirocrew.vhd
task=$(aws ec2 import-snapshot \
  --disk-container "Format=VHD,UserBucket={S3Bucket=<your-bucket>,S3Key=kirocrew.vhd}" \
  --query ImportTaskId --output text)
aws ec2 describe-import-snapshot-tasks --import-task-ids "$task"   # wait, grab SnapshotId
aws ec2 register-image --name kirocrew-0.1.3 --architecture x86_64 \
  --root-device-name /dev/xvda --ena-support --virtualization-type hvm \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=<snap-...>}"
```

Launch with a security group open to **22 only**, then reach the dashboard via
`ssh -NL 5476:localhost:5476 orre@<instance>`. Give the agent AWS through a
tightly-scoped **instance role** (IMDS), never static keys.

> Community `upload-ami` / nixos-generators helper scripts automate the
> import-snapshot + register-image dance if you'd rather not run it by hand.
