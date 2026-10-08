# Credential-less uid for Claude Remote Control (BACKLOG F1). The uid owns only
# its own home: it is not a nix trusted user, owns no sops secret, and has no
# ssh key or forge token. Pushing is blocked twice: no credentials, and the git
# config below rewrites every push URL to a scheme git cannot resolve. A
# server-side guard (protected branches) is outside this repo (F1.8). Results
# leave the box as a patch or bundle that a human reviews and pushes.
#
# The uid logs in once by hand: `sudo -u claude-remote -H claude auth login`.
# Until ~/.claude/.credentials.json exists the unit stays inactive, so there is
# no crash loop on a fresh deploy.
{ pkgs, ... }:
let
  home = "/var/lib/claude-remote";
  proxy = "http://127.0.0.1:8888";
  hardening = import ./kirocrew-hardening.nix;
in
{
  users.users.claude-remote = {
    isSystemUser = true;
    group = "claude-remote";
    inherit home;
    shell = "/run/current-system/sw/bin/bash";
    description = "Sandboxed Claude Remote Control";
  };
  users.groups.claude-remote = { };

  systemd.tmpfiles.rules = [
    "d ${home} 0700 claude-remote claude-remote -"
    "d ${home}/workspace 0700 claude-remote claude-remote -"
  ];

  # /etc entries are symlinks into the store, so the uid cannot edit this file.
  # The unit points GIT_CONFIG_GLOBAL here; nothing else sets a push URL.
  environment.etc."claude-remote/gitconfig".text = ''
    [url "invalid-push://"]
      pushInsteadOf = git@
      pushInsteadOf = ssh://
      pushInsteadOf = https://
      pushInsteadOf = http://
  '';

  # Network: IPAddressDeny=any plus IPAddressAllow=localhost covers the unit
  # and every child it spawns (all sessions and their shells); the only way out
  # is the loopback proxy (kirocrew-claude-egress.nix). hardening's IMDS-only
  # deny list is replaced by that stricter rule. No CLAUDE_CODE_DISABLE_*
  # variables: they would also disable Remote Control.
  systemd.services.claude-remote = {
    description = "Claude Remote Control (sandboxed, no push)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "tinyproxy.service"
    ];
    wants = [ "tinyproxy.service" ];
    # git for --spawn worktree, nix for `nix-shell -p` through the daemon.
    path = [
      pkgs.git
      pkgs.nix
    ];
    environment = {
      HOME = home;
      HTTPS_PROXY = proxy;
      HTTP_PROXY = proxy;
      GIT_CONFIG_GLOBAL = "/etc/claude-remote/gitconfig";
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
}
