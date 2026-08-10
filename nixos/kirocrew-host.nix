{ pkgs, ... }:

# NixOS host for the KiroCrew VM. Local QEMU profile now; the same module is
# reused for the EC2 AMI later (swap the vmVariant block for an amazon profile
# and tighten the SSH/user shortcuts — see nixos/kirocrew.md).
{
  # Placeholders so this is a complete, buildable system; the build-vm profile
  # below overrides them with a QEMU disk.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  networking.hostName = "kirocrew";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ── User ──────────────────────────────────────────────────────────────────
  users.mutableUsers = false;
  users.users.orre = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.zsh;
    # LOCAL VM ONLY. Remove and use SSH keys before building the EC2 AMI.
    initialPassword = "kirocrew";
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@laptop" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # ── SSH ─────────────────────────────────────────────────────────────────--
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true; # LOCAL VM convenience; false + keys for EC2
    };
  };

  # ── Firewall: SSH only. Dashboard (5476) stays loopback + SSH tunnel. ──────
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # ── Container runtime (backend for oci-containers in kirocrew.nix) ─────────
  virtualisation.docker.enable = true;

  # zsh as a valid login shell; home-manager (./home.nix) manages its config.
  programs.zsh.enable = true;
  environment.systemPackages = with pkgs; [ git curl ];

  # ── Local QEMU VM profile (nixos-rebuild build-vm --flake .#kirocrew) ──────
  # Forwards host 127.0.0.1:2222 → guest:22. SSH in, then tunnel 5476 over it.
  virtualisation.vmVariant.virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;
    graphics = false;
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 2222;
        guest.port = 22;
      }
    ];
  };

  system.stateVersion = "25.05";
}
