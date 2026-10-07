{ pkgs, ... }:

# NixOS module: the 1Password agent socket relay for the KiroCrew gateway.
# Split out of kirocrew-services.nix; the gateway unit (kirocrew-gateway.nix)
# sets SSH_AUTH_SOCK=/run/kirocrew/1p-agent.sock and the tmpfiles rules in
# kirocrew-services.nix create /run/kirocrew-agent and /run/kirocrew.
{
  # ── 1Password agent socket bridge ──────────────────────────────────────────
  # The launcher (`launch-ec2 portal`) forwards the operator's local 1Password
  # agent socket to /run/kirocrew-agent/orre-1p.sock (owned by orre, created by
  # sshd's -R). That socket is not readable by the kirocrew service user, so a
  # socat relay re-exposes it at /run/kirocrew/1p-agent.sock with group kirocrew
  # (0660). The gateway unit references the latter via SSH_AUTH_SOCK.
  #
  # The relay is PATH-ACTIVATED on the forwarded socket: systemd starts it the
  # moment the portal session creates the socket. It must ALSO stop when the
  # portal closes and sshd unlinks the socket — but a systemd `PathExists=` path
  # unit only *activates* its unit on existence; it does NOT stop the unit when
  # the path disappears (see systemd.path(5)). A bare `socat ...,fork` listener
  # would therefore linger and keep re-exposing the (now dangling) bridge to the
  # gateway after the operator is gone.
  #
  # So the relay watches the forwarded socket itself and exits as soon as it
  # disappears. `socat` runs in the background; a small poll loop tears the whole
  # service down when /run/kirocrew-agent/orre-1p.sock is gone, which triggers
  # ExecStopPost to remove the relayed socket. Result: the git-push bridge exists
  # only while the portal session holds the forwarded socket open.
  systemd.paths.kirocrew-1p-agent-relay = {
    description = "Watch for the operator's forwarded 1Password socket";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/run/kirocrew-agent/orre-1p.sock";
      Unit = "kirocrew-1p-agent-relay.service";
    };
  };

  systemd.services.kirocrew-1p-agent-relay = {
    description = "Relay the operator's 1Password agent socket to the kirocrew gateway";
    serviceConfig = {
      Type = "simple";
      # Relay must be able to create a socket owned by the kirocrew group and
      # connect to the orre-owned forwarded socket; run as root, drop the new
      # socket into the kirocrew group at 0660. Bound to the forwarded socket's
      # existence: when the operator's portal session ends and sshd unlinks
      # /run/kirocrew-agent/orre-1p.sock, the watcher stops socat so the bridge
      # cannot outlive the session.
      ExecStart = pkgs.writeShellScript "kirocrew-1p-agent-relay" ''
        set -eu
        upstream=/run/kirocrew-agent/orre-1p.sock
        listen=/run/kirocrew/1p-agent.sock
        ${pkgs.socat}/bin/socat \
          "UNIX-LISTEN:$listen,fork,mode=0660,user=kirocrew,group=kirocrew" \
          "UNIX-CONNECT:$upstream" &
        socat_pid=$!
        cleanup() { kill "$socat_pid" 2>/dev/null || true; }
        trap cleanup EXIT INT TERM
        # Exit (and let ExecStopPost remove the relayed socket) the moment the
        # forwarded upstream socket disappears, i.e. when the portal closes.
        while [ -S "$upstream" ] && kill -0 "$socat_pid" 2>/dev/null; do
          sleep 1
        done
      '';
      Restart = "on-failure";
      RestartSec = 2;
      # Clean up the relayed socket when the forward goes away.
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f /run/kirocrew/1p-agent.sock";
    };
  };
}
