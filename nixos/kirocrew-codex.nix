{
  config,
  lib,
  pkgs,
  ...
}:

# Optional Codex sidecar for the KiroCrew host.
#
# The app-server listens on loopback only. Reach it through the existing
# SSH-over-SSM connection, for example:
#   ssh -L 4500:127.0.0.1:4500 kirocrew
#   codex --remote ws://127.0.0.1:4500
#
# Authentication is intentionally not provisioned by Nix. Complete `codex
# login --device-auth` as the kirocrew user once, so the credential remains
# outside the repository and the Nix store.
let
  hardening = import ./kirocrew-hardening.nix;
in
{
  systemd.services.kirocrew-codex-app-server = {
    description = "Codex app-server sidecar for KiroCrew";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Same sandbox as the gateway: the shared hardening (IMDS deny included),
    # the agent's work trees writable, and the MCP secrets hidden, since Codex
    # uses none of them.
    serviceConfig = hardening // {
      Type = "simple";
      User = "kirocrew";
      Group = "kirocrew";
      WorkingDirectory = "/var/lib/kirocrew";
      ExecStart = "${pkgs.codex}/bin/codex app-server --listen ws://127.0.0.1:4500";
      Restart = "on-failure";
      RestartSec = 5;
      ProtectHome = "tmpfs";
      # Codex sandboxes the commands it runs with bubblewrap, which needs user
      # namespaces.
      RestrictNamespaces = false;
      ReadWritePaths = [
        "/var/lib/kirocrew"
        "-/var/lib/code"
        "-/var/lib/vault"
      ];
      InaccessiblePaths = [ "-/var/lib/kirocrew/secrets" ];
      PrivateDevices = true;
      Environment = [
        "HOME=/var/lib/kirocrew"
        "CODEX_HOME=/var/lib/kirocrew/.codex"
        "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      ];
    };
  };
}
