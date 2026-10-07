{ config, ... }:

# Home Manager module: sops-nix secrets for all KiroCrew hosts.
# Imported on every KiroCrew output (workstation, VM, EC2, AMI) and always
# active: the activation step runs `systemctl restart --user sops-nix` under
# `set -eu`, so a missing age key at ~/.config/sops/age/keys.txt fails the
# switch instead of being skipped.
#
# Prerequisites (EC2 only):
#   1. Age private key at ~/.config/sops/age/keys.txt (bootstrapped from 1Password)
#   2. secrets/secrets.yaml encrypted with the matching age public key
#
# Secrets are decrypted by the sops-nix.service user service and placed in
# $XDG_RUNTIME_DIR/secrets.d/ (non-persistent tmpfs). Other user services
# must order After=sops-nix.service to ensure secrets are available.
{
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

    defaultSopsFile = ./secrets/secrets.yaml;

    secrets = {
      git-ssh-key = {
        # %r is replaced with $XDG_RUNTIME_DIR at runtime
        path = "%r/secrets/git-ssh-key";
      };

      slack-bot-token = {
        path = "%r/secrets/slack-bot-token";
      };

      slack-app-token = {
        path = "%r/secrets/slack-app-token";
      };
    };

    templates."pasta-fetchers.env" = {
      path = "%r/secrets/pasta-fetchers.env";
      mode = "0400";
      content = ''
        SLACK_BOT_TOKEN=${config.sops.placeholder."slack-bot-token"}
        SLACK_APP_TOKEN=${config.sops.placeholder."slack-app-token"}
      '';
    };
  };
}
