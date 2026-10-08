# Credential-less uid for Claude Remote Control (BACKLOG F1). The uid owns only
# its own home: it is not a nix trusted user, owns no sops secret, and has no
# ssh key or forge token. Pushing is blocked twice: no credentials, and the git
# config below rewrites every push URL to a scheme git cannot resolve. A
# server-side guard (protected branches) is outside this repo (F1.8). Results
# leave the box as a patch or bundle that a human reviews and pushes.
#
# The unit that runs under this uid is added next to this file in F1.4; the
# uid logs in once by hand: `sudo -u claude-remote -H claude auth login`.
_:
let
  home = "/var/lib/claude-remote";
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
}
