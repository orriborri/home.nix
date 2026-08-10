{ lib, pkgs, ... }:

# NixOS host for the KiroCrew EC2 AMI. Built via the `amazon` nixos-generators
# format (see flake.nix packages.<system>.kirocrew-ami), which supplies the
# bootloader, a growable root filesystem, ec2.hvm, and cloud-init/amazon-init
# (the latter injects the launch key-pair into root at first boot). So this
# module deliberately omits boot.loader / fileSystems / the QEMU vmVariant that
# the local `kirocrew-host.nix` carries.
{
  networking.hostName = lib.mkDefault "kirocrew";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ── SSH: key-only ──────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Key-only root remains reachable via the launch key amazon-init injects,
      # so you're never locked out even before filling in the user key below.
      PermitRootLogin = "prohibit-password";
    };
  };

  # ── Operator user ──────────────────────────────────────────────────────────
  # home-manager (./home.nix) manages this user's environment, so the system
  # user must exist. ADD YOUR PUBLIC KEY before building, or SSH in as root
  # (launch key) and add it afterwards.
  users.mutableUsers = false;
  users.users.orre = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@laptop"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # ── Firewall: SSH only. Dashboard (5476) stays loopback + SSH tunnel. ──────
  # Keep the EC2 security group closed to 5476 as well — reach it with
  #   ssh -NL 5476:localhost:5476 orre@<instance>
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # ── Container runtime (backend for oci-containers in kirocrew.nix) ─────────
  virtualisation.docker.enable = true;

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;

  system.stateVersion = "25.05";
}
