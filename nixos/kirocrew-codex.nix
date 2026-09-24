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
{
  systemd.services.kirocrew-codex-app-server = {
    description = "Codex app-server sidecar for KiroCrew";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      User = "kirocrew";
      Group = "kirocrew";
      WorkingDirectory = "/var/lib/kirocrew";
      ExecStart = "${pkgs.codex}/bin/codex app-server --listen ws://127.0.0.1:4500";
      Restart = "on-failure";
      RestartSec = 5;
      ProtectHome = "tmpfs";
      ReadWritePaths = [ "/var/lib/kirocrew/.codex" ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      Environment = [
        "HOME=/var/lib/kirocrew"
        "CODEX_HOME=/var/lib/kirocrew/.codex"
        "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      ];
    };
  };
}
