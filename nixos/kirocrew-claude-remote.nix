# Sandboxed uid for Claude Remote Control (BACKLOG F1). The uid owns only its
# own home: it is not a nix trusted user, owns no sops secret, and holds no ssh
# key or forge token.
#
# Git access matches the KiroCrew gateway's (decided 2026-10-20, replacing the
# original no-push rule):
#   * Read: member of code-writers, so the repos under /var/lib/code and their
#     mirrors are readable. ProtectSystem=strict keeps them read-only inside
#     the unit; sessions clone them into the workspace.
#   * Push: through the operator's 1Password agent, relayed to
#     /run/claude-remote/1p-agent.sock only while `launch-ec2 portal` or
#     `launch-ec2 claude` holds the forward open. 1Password asks the operator
#     to approve each use of the key.
#   * Route: the unit can reach only the loopback proxy, which allows CONNECT
#     to port 443 alone, so GitLab SSH goes to altssh.gitlab.com:443 through
#     it, with gitlab.com's pinned host key.
#
# The uid logs in once by hand (`launch-ec2 claude` runs it). Until
# ~/.claude/.credentials.json exists the unit stays inactive, so there is no
# crash loop on a fresh deploy.
{ pkgs, ... }:
let
  home = "/var/lib/claude-remote";
  proxy = "http://127.0.0.1:8888";
  hardening = import ./kirocrew-hardening.nix;
  agentUpstream = "/run/kirocrew-agent/orre-1p.sock";
  agentSocket = "/run/claude-remote/1p-agent.sock";
in
{
  users.users.claude-remote = {
    isSystemUser = true;
    group = "claude-remote";
    extraGroups = [ "code-writers" ];
    inherit home;
    shell = "/run/current-system/sw/bin/bash";
    description = "Sandboxed Claude Remote Control";
  };
  users.groups.claude-remote = { };
  # Defined by kirocrew-security.nix on the host; declared here too so this
  # module also evaluates on its own (VM test).
  users.groups.code-writers = { };

  systemd.tmpfiles.rules = [
    "d ${home} 0700 claude-remote claude-remote -"
    "d ${home}/workspace 0700 claude-remote claude-remote -"
    "d /run/claude-remote 0700 claude-remote claude-remote -"
  ];

  # /etc entries are symlinks into the store, so the uid cannot edit these.
  environment.etc = {
    "claude-remote/gitconfig".text = ''
      [user]
        name = Claude (kirocrew)
        email = kirocrew@readpeak
      [core]
        sshCommand = ssh -F /etc/claude-remote/ssh_config
      [url "ssh://git@altssh.gitlab.com:443/"]
        insteadOf = git@gitlab.com:
        insteadOf = ssh://git@gitlab.com/
      [safe]
        directory = *
    '';
    "claude-remote/ssh_config".text = ''
      Host altssh.gitlab.com
        User git
        Port 443
        HostKeyAlias gitlab.com
        UserKnownHostsFile /etc/claude-remote/known_hosts
        StrictHostKeyChecking yes
        ProxyCommand ${pkgs.socat}/bin/socat - PROXY:127.0.0.1:%h:%p,proxyport=8888
    '';
    # Same key as known_hosts_kirocrew (kirocrew-config.nix); altssh serves it.
    "claude-remote/known_hosts".text = ''
      gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
    '';
  };

  # Network: IPAddressDeny=any plus IPAddressAllow=localhost covers the unit
  # and every child it spawns (all sessions and their shells); the only way out
  # is the loopback proxy (kirocrew-claude-egress.nix). hardening's IMDS-only
  # deny list is replaced by that stricter rule. No CLAUDE_CODE_DISABLE_*
  # variables: they would also disable Remote Control.
  systemd.services.claude-remote = {
    description = "Claude Remote Control (sandboxed)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "tinyproxy.service"
    ];
    wants = [ "tinyproxy.service" ];
    # git for --spawn worktree and pushes, openssh for git's ssh transport,
    # nix for `nix-shell -p` through the daemon.
    path = [
      pkgs.git
      pkgs.nix
      pkgs.openssh
    ];
    environment = {
      HOME = home;
      HTTPS_PROXY = proxy;
      HTTP_PROXY = proxy;
      GIT_CONFIG_GLOBAL = "/etc/claude-remote/gitconfig";
      SSH_AUTH_SOCK = agentSocket;
    };
    unitConfig.ConditionPathExists = "${home}/.claude/.credentials.json";
    serviceConfig = hardening // {
      User = "claude-remote";
      Group = "claude-remote";
      WorkingDirectory = "${home}/workspace";
      ExecStart = "${pkgs.claude-code}/bin/claude remote-control --name kirocrew --spawn worktree";
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      ReadWritePaths = [ home ];
      UnsetEnvironment = [
        "ANTHROPIC_API_KEY"
        "ANTHROPIC_AUTH_TOKEN"
      ];
      Restart = "always";
      RestartSec = 30;
    };
  };

  # Relay the forwarded 1Password agent to the claude-remote uid, the same way
  # kirocrew-1p-relay.nix does for the gateway: started when the forward
  # appears, stopped (and the socket removed) when it disappears, so push
  # access never outlives the operator's session.
  systemd.paths.claude-remote-1p-agent-relay = {
    description = "Watch for the operator's forwarded 1Password socket (claude-remote)";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = agentUpstream;
      Unit = "claude-remote-1p-agent-relay.service";
    };
  };

  systemd.services.claude-remote-1p-agent-relay = {
    description = "Relay the operator's 1Password agent socket to claude-remote";
    serviceConfig = {
      Type = "simple";
      ExecStart = pkgs.writeShellScript "claude-remote-1p-agent-relay" ''
        set -eu
        upstream=${agentUpstream}
        listen=${agentSocket}
        ${pkgs.socat}/bin/socat \
          "UNIX-LISTEN:$listen,fork,mode=0600,user=claude-remote,group=claude-remote" \
          "UNIX-CONNECT:$upstream" &
        socat_pid=$!
        cleanup() { kill "$socat_pid" 2>/dev/null || true; }
        trap cleanup EXIT INT TERM
        while [ -S "$upstream" ] && kill -0 "$socat_pid" 2>/dev/null; do
          sleep 1
        done
      '';
      Restart = "on-failure";
      RestartSec = 2;
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f ${agentSocket}";
    };
  };
}
