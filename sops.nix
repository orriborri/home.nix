{ config, ... }:

# Home Manager module: sops-nix secrets for the kirocrew EC2 instance.
# Decrypts age-encrypted secrets at user service activation time.
#
# Prerequisites:
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

    secrets.git-ssh-key = {
      # %r is replaced with $XDG_RUNTIME_DIR at runtime
      path = "%r/secrets/git-ssh-key";
    };
  };
}
