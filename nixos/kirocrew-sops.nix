{ config, ... }:

# NixOS (system-level) sops-nix configuration for the dedicated `kirocrew`
# service user.
#
# On headless/EC2 hosts the gateway runs as a SYSTEM service under the
# unprivileged `kirocrew` user (see kirocrew-services.nix). That user has no
# home-manager instance and no login session, so the HM sops module
# (sops.nix, imported under home-manager.users.orre) cannot provision secrets
# for it. This module fills that gap with system-level sops-nix so the gateway
# can own the vault git repository end-to-end (Model 2): clone/push over SSH
# and unlock the git-crypt-encrypted contents.
#
# Design:
#   * Age private key lives at /var/lib/sops-nix/key.txt, root:root 0400.
#     sops-install-secrets runs as root at activation, so no service user
#     needs to read it. It must NOT live under a service user's home: the
#     agents run as `kirocrew`, and a key they can read decrypts every secret
#     on the box, including the ones owned by pasta and obsidian-web. It is
#     the SAME age key already tracked in .sops.yaml (1Password item
#     "kirocrew-age"), so secrets/secrets.yaml does NOT need re-encryption.
#   * Decrypted secrets are written to persistent paths inside each owning
#     user's home (under ReadWritePaths, not masked by ProtectHome).
#
# Bootstrap: `launch-ec2` places the key before every rebuild
# (launcher.py _bootstrap_age_key). By hand:
#   op read "op://Readpeak/kirocrew-age/private key" \
#     | install -D -m 400 -o root -g root /dev/stdin /var/lib/sops-nix/key.txt
#
# sops-install-secrets runs at activation; other services order After it.
{
  # Remove the key from its old location in the agent-readable kirocrew home,
  # but only once the root-owned copy exists, so a box is never left keyless.
  # Also remove the forge SSH key this module used to decrypt for kirocrew:
  # sops-nix does not delete files for secrets that are no longer declared.
  system.activationScripts.removeLegacyAgeKey = {
    deps = [ "setupSecrets" ];
    text = ''
      if [ -s /var/lib/sops-nix/key.txt ]; then
        rm -f /var/lib/kirocrew/.config/sops/age/keys.txt
      fi
      rm -f /var/lib/kirocrew/secrets/git-ssh-key
    '';
  };

  sops = {
    age.keyFile = "/var/lib/sops-nix/key.txt";
    # Do not require the key at build/eval time; only at activation. If absent,
    # activation logs an error but evaluation still succeeds.
    age.generateKey = false;

    defaultSopsFile = ../secrets/secrets.yaml;

    # GitLab deploy token for the vault repo (HTTPS auth). Username and token
    # are separate secrets; kirocrew-vault-git.nix feeds them to git via
    # GIT_ASKPASS so the token never lands in .git/config.
    secrets.vault-git-token = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/vault-git-token";
    };
    secrets.vault-git-token-user = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/vault-git-token-user";
    };

    # git-crypt symmetric key: unlocks the encrypted vault after clone. Base64
    # of the raw key exported by the workstation wizard.
    secrets.vault-git-crypt-key = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/vault-git-crypt-key";
    };

    # Xpra authentication password for the browser-Obsidian session
    # (kirocrew-obsidian-xpra.nix). Provisioned to the display user's private
    # state, where the Xpra `file` auth module reads it. sops-nix decrypts as
    # root using the kirocrew age key, then chowns to obsidian-web.
    secrets.xpra-password = {
      owner = config.users.users.obsidian-web.name;
      inherit (config.users.users.obsidian-web) group;
      mode = "0400";
      path = "/var/lib/obsidian-web/secrets/xpra-password";
    };

    # ── Pasta external-source fetch credentials ─────────────────────────────
    # Consumed by the pasta-fetch-external service (kirocrew-services.nix),
    # which runs `kb sync` for the forge/messaging sources. Owned by the pasta
    # user (the fetcher's identity) and decrypted to its private secrets dir.
    # The fetch unit's ExecStartPre reconstructs the exact token files the
    # helper CLIs expect (`~/.config/{slack,linear}-api/token.json`) and logs
    # glab in from these — the raw values never land in the Nix store or config.

    # Linear GraphQL API key (`lin_api_...`). Read by the `linear-api` helper.
    secrets.pasta-linear-api-key = {
      owner = config.users.users.pasta.name;
      inherit (config.users.users.pasta) group;
      mode = "0400";
      path = "/var/lib/pasta/secrets/linear-api-key";
      key = "linear-api-key";
    };

    # Slack bot/app tokens used by the pasta fetcher process environment.
    secrets.pasta-slack-bot-token = {
      owner = config.users.users.pasta.name;
      inherit (config.users.users.pasta) group;
      mode = "0400";
      path = "/var/lib/pasta/secrets/slack-bot-token";
      key = "slack-bot-token";
    };
    secrets.pasta-slack-app-token = {
      owner = config.users.users.pasta.name;
      inherit (config.users.users.pasta) group;
      mode = "0400";
      path = "/var/lib/pasta/secrets/slack-app-token";
      key = "slack-app-token";
    };

    # GitLab personal access token (`glpat-...`). Used both for `glab` auth
    # (MR fetch) and to clone the `[repos]` over HTTPS (git fetch), so the
    # pasta user needs no SSH key on the box.
    secrets.pasta-gitlab-token = {
      owner = config.users.users.pasta.name;
      inherit (config.users.users.pasta) group;
      mode = "0400";
      path = "/var/lib/pasta/secrets/gitlab-token";
      key = "gitlab-token";
    };

    # ── CFM Tips MCP server AWS credentials ─────────────────────────────────
    # Read-only AWS keys for the cfm-tips cost-optimization MCP server the
    # gateway spawns (kirocrew-services.nix mcp.json). These belong to a
    # DEDICATED IAM principal that carries ONLY the consolidated read-only cost
    # policy from the CFM Tips README — not the instance role, which the gateway
    # cannot reach (IMDS is blocked by IPAddressDeny). Owned by kirocrew and
    # composed into an EnvironmentFile by the sops template below, so the
    # gateway process holds CFM_TIPS_AWS_* and KiroCrew resolves the
    # ${env:CFM_TIPS_AWS_*} refs in mcp.json at session runtime.
    secrets.cfm-tips-aws-access-key-id = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/cfm-tips-aws-access-key-id";
      key = "cfm-tips-aws-access-key-id";
    };
    secrets.cfm-tips-aws-secret-access-key = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/cfm-tips-aws-secret-access-key";
      key = "cfm-tips-aws-secret-access-key";
    };

    # ── Slack MCP server token (gateway) ────────────────────────────────────
    # A SECOND decrypt target for the SAME sops `slack-bot-token` (the pasta
    # user gets its own copy above at /var/lib/pasta/secrets/slack-bot-token).
    # The gateway runs as `kirocrew` and cannot read pasta's 0400 pasta-owned file,
    # so it needs its own kirocrew-owned copy of the identical secret. Consumed
    # by the Slack MCP server the gateway spawns (kirocrew-services.nix
    # mcp.json), composed into an EnvironmentFile by the template below so the
    # gateway process holds SLACK_TOKEN and KiroCrew resolves the
    # ${env:SLACK_TOKEN} ref in mcp.json at session runtime.
    #
    # This is the Slack BOT token (`xoxb-...`); the user token (`xoxp-...`)
    # was retired. Bot tokens cannot call search.messages, so the MCP's
    # slack_search_messages tool fails with not_allowed_token_type; history,
    # users and chat.postMessage work within the bot's scopes.
    secrets.kirocrew-slack-token = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/slack-token";
      key = "slack-bot-token";
    };
  };

  # Compose the two AWS secrets into a systemd EnvironmentFile (KEY=value
  # lines). sops secrets are raw values, so they cannot be an EnvironmentFile
  # directly; a template renders the KEY=value form with the secrets spliced in
  # via config.sops.placeholder (substituted at activation, never in the Nix
  # store). The gateway unit references this path as an EnvironmentFile.
  sops.templates."cfm-tips-aws.env" = {
    owner = config.users.users.kirocrew.name;
    inherit (config.users.users.kirocrew) group;
    mode = "0400";
    path = "/var/lib/kirocrew/secrets/cfm-tips-aws.env";
    content = ''
      CFM_TIPS_AWS_ACCESS_KEY_ID=${config.sops.placeholder."cfm-tips-aws-access-key-id"}
      CFM_TIPS_AWS_SECRET_ACCESS_KEY=${config.sops.placeholder."cfm-tips-aws-secret-access-key"}
    '';
  };

  # Slack token as a systemd EnvironmentFile (KEY=value) for the gateway. Same
  # rationale as cfm-tips: sops secrets are raw values, so a template renders
  # the KEY=value line with the secret spliced in via config.sops.placeholder
  # (substituted at activation, never written to the Nix store). The gateway
  # unit references this path as an EnvironmentFile, and mcp.json's slack entry
  # reads ${env:SLACK_TOKEN}.
  sops.templates."kirocrew-slack.env" = {
    owner = config.users.users.kirocrew.name;
    inherit (config.users.users.kirocrew) group;
    mode = "0400";
    path = "/var/lib/kirocrew/secrets/kirocrew-slack.env";
    content = ''
      SLACK_TOKEN=${config.sops.placeholder."kirocrew-slack-token"}
    '';
  };

  sops.templates."pasta-fetchers.env" = {
    owner = config.users.users.pasta.name;
    inherit (config.users.users.pasta) group;
    mode = "0400";
    path = "/var/lib/pasta/secrets/pasta-fetchers.env";
    content = ''
      SLACK_BOT_TOKEN=${config.sops.placeholder."pasta-slack-bot-token"}
      SLACK_APP_TOKEN=${config.sops.placeholder."pasta-slack-app-token"}
    '';
  };
}
