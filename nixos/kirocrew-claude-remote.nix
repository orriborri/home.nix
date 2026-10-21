# Sandboxed uid for Claude Remote Control (BACKLOG F1). The uid owns only its
# own home: it is not a nix trusted user, holds no ssh key, and owns exactly one
# sops secret, the GitLab token below.
#
# Git access (decided 2026-10-20; the operator uses this as their coding agent):
#   * Read: member of code-writers, so the repos under /var/lib/code and their
#     mirrors are readable. ProtectSystem=strict keeps them read-only inside
#     the unit; sessions clone them into the workspace.
#   * Push and merge requests: a GitLab fine-grained personal access token
#     limited to Code: Push and Merge Request: Create on the readpeak group
#     (sops `claude-remote-gitlab-token`, kirocrew-sops.nix), passed to the
#     unit as GITLAB_TOKEN. git uses it over HTTPS through a credential helper.
#   * Route: the unit can reach only the loopback proxy, which allows
#     gitlab.com on 443, so git@gitlab.com: URLs are rewritten to HTTPS.
#
# The uid logs in once by hand (`launch-ec2 claude` runs it). Until
# ~/.claude/.credentials.json exists the unit stays inactive, so there is no
# crash loop on a fresh deploy.
{ lib, pkgs, ... }:
let
  home = "/var/lib/claude-remote";
  proxy = "http://127.0.0.1:8888";
  hardening = import ./kirocrew-hardening.nix;

  # Skills every session loads (agent-pipeline issue 05). Matt Pocock's come
  # from the checkout repo-sync keeps at the revision pinned in repos.toml;
  # read-only inside the unit (ProtectSystem=strict).
  manifest = builtins.fromTOML (builtins.readFile ../config/repos.toml);
  mattpocock = lib.findFirst (
    repo: repo.path == "code/mattpocock-skills"
  ) (throw "repos.toml has no code/mattpocock-skills entry") manifest.repos;
  # Same layout as destinationFor in kirocrew-code.nix.
  mattpocockSkill =
    name: "/var/lib/code/${lib.removePrefix "code/" mattpocock.path}/skills/engineering/${name}";
  # Our own skills ship from ./claude-remote-skills in the store.
  ownSkill = name: ./claude-remote-skills + "/${name}";
  skills = pkgs.linkFarm "claude-remote-skills" (
    lib.genAttrs [ "tdd" "code-review" ] mattpocockSkill
    // lib.genAttrs [ "analyze-ticket" "implement-ticket" ] ownSkill
  );

  # git credential helper: answers `get` for gitlab.com with the token from the
  # unit's environment, and stores nothing.
  gitlabCredential = pkgs.writeShellScript "claude-remote-gitlab-credential" ''
    [ "$1" = get ] && [ -n "''${GITLAB_TOKEN:-}" ] || exit 0
    echo username=oauth2
    echo "password=$GITLAB_TOKEN"
  '';
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
    "d ${home}/.claude 0700 claude-remote claude-remote -"
    # User-level instructions every session loads; read-only (store symlink).
    "L+ ${home}/.claude/CLAUDE.md - - - - /etc/claude-remote/CLAUDE.md"
    "L+ ${home}/.claude/skills - - - - /etc/claude-remote/skills"
  ];

  # /etc entries are symlinks into the store, so the uid cannot edit these.
  environment.etc = {
    "claude-remote/gitconfig".text = ''
      [user]
        name = Claude (kirocrew)
        email = kirocrew@readpeak
      [url "https://gitlab.com/"]
        insteadOf = git@gitlab.com:
        insteadOf = ssh://git@gitlab.com/
      [credential "https://gitlab.com"]
        helper = ${gitlabCredential}
      [safe]
        directory = *
    '';
    "claude-remote/CLAUDE.md".text = ''
      # This machine: kirocrew (Claude Remote Control)

      ## Repositories
      - Readpeak repos are at `/var/lib/code/readpeak/<repo>`. They are
        read-only here. Work in a clone in the current directory:
        `git clone /var/lib/code/readpeak/<repo>`, then
        `git remote set-url origin git@gitlab.com:readpeak/<repo>.git`.
      - The local copies are synced from GitLab by the KiroCrew host. The
        GitLab token cannot read, so `git fetch`/`git pull` from GitLab may be
        refused; base work on the local copy.

      ## Push and merge requests
      - git reaches GitLab over HTTPS with `$GITLAB_TOKEN`; `git@gitlab.com:`
        URLs are rewritten automatically. Do not ask for SSH keys.
      - The token can only push code and create merge requests. It cannot read
        projects through the API, comment, approve or merge.
      - Push to a new branch, never to `main`. Then create the merge request:

        ```
        curl --fail-with-body -sS -X POST \
          -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
          --data-urlencode source_branch=<branch> \
          --data-urlencode target_branch=main \
          --data-urlencode title="<title>" \
          --data-urlencode description="<description>" \
          https://gitlab.com/api/v4/projects/readpeak%2F<repo>/merge_requests
        ```

      ## Code graph
      - A read-only code-review-graph MCP server for all repos runs at
        `http://127.0.0.1:5555/mcp` (`/etc/claude-remote/mcp.json`). Pass
        `repo_root=/var/lib/code/readpeak/<repo>` to per-repo tools; use
        `cross_repo_search_tool` to search every repo at once.

      ## Network
      - All traffic goes through a proxy that allows only Anthropic, GitHub,
        gitlab.com, the npm/PyPI/crates registries and the NixOS caches. Other
        hosts are refused by design; do not try to work around it.
    '';
    "claude-remote/skills".source = skills;
    # Search hidden files (.gitlab-ci.yml, .env.example) but not .git. Kept
    # here because a '!' glob on the command line asks for permission on
    # every search.
    "claude-remote/ripgreprc".text = ''
      --hidden
      --glob=!.git
    '';
    # Loaded with `claude --mcp-config /etc/claude-remote/mcp.json`. The
    # server is code-review-graph-mcp (kirocrew-code.nix), reached directly
    # over loopback (NO_PROXY below).
    "claude-remote/mcp.json".text = builtins.toJSON {
      mcpServers.code-review-graph = {
        type = "http";
        url = "http://127.0.0.1:5555/mcp";
      };
    };
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
    # git for clones and pushes, nix for `nix-shell -p` through the daemon,
    # ripgrep for analyze-ticket's literal search.
    path = [
      pkgs.git
      pkgs.nix
      pkgs.ripgrep
    ];
    environment = {
      HOME = home;
      HTTPS_PROXY = proxy;
      HTTP_PROXY = proxy;
      # The crg MCP server is on loopback; the proxy filter would refuse it.
      NO_PROXY = "127.0.0.1,localhost";
      RIPGREP_CONFIG_PATH = "/etc/claude-remote/ripgreprc";
      GIT_CONFIG_GLOBAL = "/etc/claude-remote/gitconfig";
    };
    unitConfig.ConditionPathExists = "${home}/.claude/.credentials.json";
    serviceConfig = hardening // {
      User = "claude-remote";
      Group = "claude-remote";
      WorkingDirectory = "${home}/workspace";
      # same-dir: sessions share the workspace and clone the repos they need
      # into it. worktree mode needs the workspace itself to be one git repo.
      ExecStart = "${pkgs.claude-code}/bin/claude remote-control --name kirocrew --spawn same-dir";
      # GITLAB_TOKEN=..., rendered by sops (kirocrew-sops.nix). Optional, so
      # the unit still starts on a box without the secret.
      EnvironmentFile = "-${home}/secrets/gitlab.env";
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
