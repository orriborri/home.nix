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
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    ./kirocrew-security.nix
    ./kirocrew-services.nix
    ./kirocrew-vault.nix
  ];

  # The stock AMI has a 249 MiB /boot partition, which fits two kernel/initrd
  # pairs but fills up if GRUB retains additional generations.
  boot.loader.grub.configurationLimit = 2;

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
      # Allow the launcher's `-R /run/kirocrew-agent/orre-1p.sock` forward
      # (1Password agent bridge) to replace a stale socket on reconnect.
      StreamLocalBindUnlink yes
    '';
  };

  # ── SSM agent: the box's outbound control channel ──────────────────────────
  # Enables Session Manager (shell), SSH-over-SSM (nixos-rebuild --target-host
  # via a ProxyCommand), and port-forwarding (dashboard 5476) with ZERO inbound
  # ports. Requires an instance profile carrying AmazonSSMManagedInstanceCore
  # (attach at launch with --iam-instance-profile). The stock NixOS AMI does not
  # run this agent, so the FIRST rebuild bootstraps it (see nixos/kirocrew.md).
  services.amazon-ssm-agent.enable = true;

  # ── User settings ──────────────────────────────────────────────────────────
  # apply-ec2-data installs the EC2 launch key for root at boot; the static
  # immutable-user lockout check cannot observe that runtime credential.
  users.allowNoPasswordLogin = true;
  users.mutableUsers = false;

  # ── Note: bwrap sandbox status ─────────────────────────────────────────────
  # kiro-cli's bwrap (FHS sandbox) fails on some EC2/Amazon virtualisation
  # environments because mount(/, MS_SLAVE) is blocked. KiroCrew strict sandbox
  # uses Linux user/mount namespaces instead. If namespace creation fails on the
  # target instance, the gateway will refuse to start (fail closed).

  # ── Packages ───────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # ── X11-forwarded browsers ───────────────────────────────────────────────
    # Connect with: ssh -XC via the SSM ProxyCommand, then run chromium/firefox.
    chromium
    firefox
    xauth
    dejavu_fonts
    liberation_ttf
    # ── Vault synchronization and read-only S3 inspection mount ─────────────
    mountpoint-s3
    fuse3
    # ── Web terminal ─────────────────────────────────────────────────────────
    ttyd
    zellij
  ];

  # ── Web terminal: ttyd + zellij on port 7681 ──────────────────────────────
  # Every browser tab attaches to the same persistent Zellij session.
  # Accessible via SSM port-forward or Tailscale.
  systemd.services.ttyd-zellij = {
    description = "Web terminal (ttyd + zellij)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "orre";
      Group = "users";
      ExecStart = ''
        ${pkgs.ttyd}/bin/ttyd \
          --port 7681 \
          --interface 127.0.0.1 \
          --writable \
          ${pkgs.zellij}/bin/zellij attach --create main
      '';
      Restart = "always";
      RestartSec = 3;
    };
  };

  # ── Vault storage ─────────────────────────────────────────────────────────
  # Agents write the local POSIX copy at /var/lib/vault. This read-only
  # Mountpoint view exposes the raw S3 state for inspection and recovery only;
  # normal edits flow through the conflict-aware bisync service.
  programs.fuse = {
    enable = true;
    userAllowOther = true;
  };

  systemd.tmpfiles.rules = [
    "d /tmp 1777 root root -"
    "d /mnt/readpeak-vault-s3 0755 root root -"
  ];

  systemd.services.readpeak-vault-s3-mount = {
    description = "Read-only Mountpoint view of the ReadPeak Obsidian S3 bucket";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "mount-readpeak-vault-s3" ''
        set -euo pipefail
        if ${pkgs.util-linux}/bin/mountpoint -q /mnt/readpeak-vault-s3; then
          exit 0
        fi
        ${pkgs.mountpoint-s3}/bin/mount-s3 \
          readpeak-vault-sync \
          /mnt/readpeak-vault-s3 \
          --read-only \
          --allow-other \
          --region eu-central-1
      '';
      ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u /mnt/readpeak-vault-s3";
    };
  };

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;

  system.stateVersion = "25.05";
}
