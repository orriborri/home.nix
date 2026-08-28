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
  # Minimal set for the workspace. ttyd, Tailscale, and Docker removed;
  # access is SSM-only. Browsers retained for X11-forwarded testing.
  environment.systemPackages = with pkgs; [
    # ── X11-forwarded browsers ───────────────────────────────────────────────
    # Connect with: ssh -XC via the SSM ProxyCommand, then run chromium/firefox.
    chromium
    firefox
    xauth
    dejavu_fonts
    liberation_ttf
  ];

  # ── Vault: Git-backed checkout replaces S3 FUSE mount ─────────────────────
  # The vault is now a Git checkout at /var/lib/vault, managed by the
  # kirocrew-vault.nix module. The old S3 FUSE mount is removed.
  # Synchronization happens through Git fetch/push, not FUSE.
  programs.fuse.enable = true; # Retained for potential future use

  # ── Ensure /tmp exists (some NixOS AMIs lack it until first tmpfiles run) ──
  systemd.tmpfiles.rules = [ "d /tmp 1777 root root -" ];

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;

  system.stateVersion = "25.05";
}
