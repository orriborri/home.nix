{
  config,
  lib,
  pkgs,
  ...
}:

# NixOS module: dedicated service identities and security hardening for the
# simplified KiroCrew workspace.
#
# Creates three identities:
#   admin (orre) — human administration with sudo, no docker
#   kirocrew     — gateway and agent workloads, no sudo/docker/wheel
#   pasta        — vault indexer, read-only vault access, writable index only
#
# Tightens the firewall: SSM-only by default, no broad trusted interfaces.
{
  # ── Service users ──────────────────────────────────────────────────────────

  users.groups.kirocrew = { };
  users.groups.pasta = { };

  # Shared group for files that both kirocrew and pasta need to read
  # (e.g. the vault checkout).
  users.groups.vault-readers = { };

  users.users.kirocrew = {
    isSystemUser = true;
    group = "kirocrew";
    extraGroups = [ "vault-readers" ];
    home = "/var/lib/kirocrew";
    createHome = true;
    shell = pkgs.bashInteractive;
    description = "KiroCrew gateway and agent workloads";
  };

  users.users.pasta = {
    isSystemUser = true;
    group = "pasta";
    extraGroups = [ "vault-readers" ];
    home = "/var/lib/pasta";
    createHome = true;
    shell = pkgs.bashInteractive;
    description = "Pasta vault indexer";
  };

  # ── Admin user (orre) — tightened ──────────────────────────────────────────
  # Retains sudo for human administration. Removed from docker group.
  # Docker is disabled entirely; if needed later, a separate builder identity
  # can be introduced.
  users.users.orre = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # Add your SSH public key here before deploying
    ];
  };

  # sudo requires password for admin operations (remove passwordless sudo).
  security.sudo.wheelNeedsPassword = true;

  # ── Docker disabled ────────────────────────────────────────────────────────
  # No identity needs Docker for normal agent-assisted development.
  # Re-enable with a dedicated builder identity if privileged builds are needed.
  virtualisation.docker.enable = lib.mkForce false;

  # ── Firewall: SSM-only, no broad trusted interfaces ────────────────────────
  # SSM uses outbound HTTPS (443) only — no inbound ports required.
  # SSH (22) allowed for bootstrap and SSM SSH tunneling.
  # Tailscale removed from initial config; add back when explicitly needed.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ ];
    # Explicitly clear any broad trusted interfaces.
    trustedInterfaces = [ ];
  };

  # ── Credential isolation ───────────────────────────────────────────────────
  # Ensure kirocrew and pasta home directories are not world-readable.
  system.activationScripts.kirocrew-home-perms = lib.stringAfter [ "users" ] ''
    chmod 750 /var/lib/kirocrew 2>/dev/null || true
    chmod 750 /var/lib/pasta 2>/dev/null || true
  '';

  # ── Remove ttyd-zellij (was running as orre, writable, on 0.0.0.0) ────────
  # Access the workspace through SSM port-forwarding instead.
  # systemd.services.ttyd-zellij is not defined here; the old definition
  # in kirocrew-ec2.nix must be removed.
}
