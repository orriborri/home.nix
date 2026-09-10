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
# Design (kirocrew owns its own key):
#   * Age private key lives in the kirocrew user's home at
#     /var/lib/kirocrew/.config/sops/age/keys.txt. It is the SAME age key
#     already tracked in .sops.yaml (1Password item "kirocrew-age"), so
#     secrets/secrets.yaml does NOT need re-encryption — only the private key
#     is bootstrapped into kirocrew's home instead of orre's.
#   * Decrypted secrets are written to persistent paths inside the kirocrew
#     home (under ReadWritePaths, not masked by ProtectHome).
#
# One-time bootstrap on the instance (also see nixos/kirocrew.md):
#   install -d -m 700 -o kirocrew -g kirocrew /var/lib/kirocrew/.config/sops/age
#   op read "op://Readpeak/kirocrew-age/private key" \
#     | install -m 600 -o kirocrew -g kirocrew /dev/stdin \
#         /var/lib/kirocrew/.config/sops/age/keys.txt
#
# sops-install-secrets runs at activation; other services order After it.
{
  sops = {
    age.keyFile = "/var/lib/kirocrew/.config/sops/age/keys.txt";
    # Do not require the key at build/eval time; only at activation. If absent,
    # activation logs an error but evaluation still succeeds.
    age.generateKey = false;

    defaultSopsFile = ../secrets/secrets.yaml;

    # Git transport key: still used by other flows that clone as kirocrew over
    # SSH. Retained; harmless if unused by the vault (which uses HTTPS below).
    secrets.git-ssh-key = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      path = "/var/lib/kirocrew/secrets/git-ssh-key";
    };

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
  };
}
