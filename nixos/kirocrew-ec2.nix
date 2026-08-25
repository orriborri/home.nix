{ pkgs, modulesPath, ... }:

# NixOS host for the KiroCrew EC2 instance. Works two ways:
#   1. Baked AMI  — via the `amazon` nixos-generators format
#      (flake.nix packages.<system>.kirocrew-ami).
#   2. Live box   — `nixos-rebuild --flake .#kirocrew-ec2 --target-host` onto a
#      running official NixOS AMI.
# For (2) the config must itself supply the EC2 boot/rootfs/amazon-init, so we
# import the canonical amazon-image profile below. That import is idempotent:
# nixos-generators' `amazon` format pulls in the SAME module, and NixOS dedupes
# imports by path, so this is safe for the baked-AMI path too.
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  networking.hostName = "kirocrew";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ── SSH: key-only, reachable over SSM (no public port) ─────────────────────
  # sshd still runs, but you reach it THROUGH the SSM tunnel (AWS-StartSSHSession),
  # so the security group needs no inbound rule. root stays key-only via the
  # launch key amazon-init injects.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      X11Forwarding = true;
    };
    extraConfig = ''
      XAuthLocation ${pkgs.xauth}/bin/xauth
    '';
  };

  # ── SSM agent: the box's outbound control channel ──────────────────────────
  # Enables Session Manager (shell), SSH-over-SSM (nixos-rebuild --target-host
  # via a ProxyCommand), and port-forwarding (dashboard 5476) with ZERO inbound
  # ports. Requires an instance profile carrying AmazonSSMManagedInstanceCore
  # (attach at launch with --iam-instance-profile). The stock NixOS AMI does not
  # run this agent, so the FIRST rebuild bootstraps it (see nixos/kirocrew.md).
  services.amazon-ssm-agent.enable = true;

  # ── Operator user ──────────────────────────────────────────────────────────
  # home-manager (./home.nix) manages this user's environment, so the system
  # user must exist. ADD YOUR PUBLIC KEY before building, or SSH in as root
  # (launch key) and add it afterwards.
  # apply-ec2-data installs the EC2 launch key for root at boot; the static
  # immutable-user lockout check cannot observe that runtime credential.
  users.allowNoPasswordLogin = true;
  users.mutableUsers = false;
  users.users.orre = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@laptop"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # ── Firewall ───────────────────────────────────────────────────────────────
  # Steady state is SSM-only: the security group needs NO inbound rule, and both
  # SSH-over-SSM and the 5476 dashboard forward ride the SSM channel. Port 22 is
  # allowed in the host firewall purely so a one-time bootstrap SSH (temporary SG
  # ingress) can enable the SSM agent on the stock AMI; once SSM is up, drop the
  # SG ingress and never open a port again.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # ── Note: bwrap sandbox is NOT used ─────────────────────────────────────────
  # kiro-cli's bwrap (FHS sandbox) fails on EC2/Amazon virtualisation because
  # mount(/, MS_SLAVE) is blocked. The kirocrew service uses sandbox=off and the
  # activation script symlinks the unwrapped kiro-cli binary directly.
  # No kernel.unprivileged_userns_clone or security.unprivilegedUsernsClone needed.

  # ── Container runtime (for user workloads — KiroCrew itself runs native) ────
  virtualisation.docker.enable = true;

  # ── Vault: S3-backed Obsidian vault via Mountpoint for Amazon S3 ───────────
  # The vault bucket (readpeak-vault-sync) is mounted at the same path as the
  # local workstation. IAM permissions come from the instance profile
  # (kirocrew-ssm role). The local workstation pushes to S3 on a timer; EC2
  # reads/writes through the FUSE mount.
  environment.systemPackages = with pkgs; [
    mountpoint-s3

    # ── X11-forwarded browsers ───────────────────────────────────────────────
    # Connect with: ssh -XC via the SSM ProxyCommand, then run chromium/firefox.
    chromium            # google-chrome unavailable on aarch64; chromium works
    firefox
    xauth               # X11 forwarding auth (sshd needs this)
    dejavu_fonts         # readable default fonts for browsers
    liberation_ttf       # metric-compatible web fonts
  ];

  systemd.services.mount-vault-s3 = {
    description = "Mount Obsidian vault from S3";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = "orre";
      Group = "users";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /home/orre/Obsidian/Readpeak";
      ExecStart = "${pkgs.mountpoint-s3}/bin/mount-s3 readpeak-vault-sync /home/orre/Obsidian/Readpeak --region eu-central-1 --allow-delete --allow-overwrite --dir-mode 0755 --file-mode 0644";
      ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /home/orre/Obsidian/Readpeak";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;

  system.stateVersion = "25.05";
}
