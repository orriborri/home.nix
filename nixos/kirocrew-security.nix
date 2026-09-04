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

  # Shared group for the code repository tree at /var/lib/code. Both the
  # operator (orre), who clones/pulls the repos, and the gateway (kirocrew),
  # whose agent edits them, are members so they can read and write the same
  # working trees. The tree is setgid + group-writable (see kirocrew-code.nix)
  # so new files inherit this group.
  users.groups.code-writers = { };

  users.users.kirocrew = {
    isSystemUser = true;
    group = "kirocrew";
    extraGroups = [ "vault-readers" "code-writers" ];
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
    extraGroups = [ "wheel" "code-writers" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # Add your SSH public key here before deploying
    ];
  };

  # Passwordless sudo for wheel users. The instance is SSM-only with key-based
  # SSH; there is no password set (mutableUsers = false), so requiring one would
  # lock out sudo entirely.
  security.sudo.wheelNeedsPassword = false;

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
