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
    ./kirocrew-review-agents.nix
    ./kirocrew-review-skills.nix
    ./kirocrew-assistant.nix
    ./kirocrew-vault-git.nix
    ./kirocrew-sops.nix
    ./kirocrew-code.nix
    ./kirocrew-obsidian-xpra.nix
    ./kirocrew-ollama.nix
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

  # ── Memory: compressed RAM swap ────────────────────────────────────────────
  # A safety net against transient memory spikes. The gateway on the pinned
  # v0.7.0-insider build can peak >13G under concurrent member load; the box was
  # resized to t4g.2xlarge (30G) which fits that with headroom, but a spike must
  # never OOM-kill or crash-loop the gateway again. A swap FILE is not viable —
  # the root volume is ~99% full — so use zram: compressed, RAM-backed swap that
  # needs no disk. Sized to 50% of RAM (~15G of compressed backing) so a burst
  # pages into compressed RAM instead of hitting the wall.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
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
    # ── Terminal multiplexer ─────────────────────────────────────────────────
    # Zellij stays available for the SSH-over-SSM connection and the
    # `kirocrew-zellij` launcher. There is no browser terminal: administrator
    # shell access is SSM-only (no writable web terminal on any port).
    zellij
    # ── Vault git management ──────────────────────────────────────────────────
    git
    git-crypt
  ];

  # Vault storage is a git-crypt-encrypted git checkout managed by
  # kirocrew-vault-git.nix (KiroCrew owns the repo). The former read-only S3
  # mount module (kirocrew-vault.nix) is retained but no longer imported.
  systemd.tmpfiles.rules = [
    "d /tmp 1777 root root -"
  ];

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;

  system.stateVersion = "25.05";
}
