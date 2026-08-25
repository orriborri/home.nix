{ config, ... }:

# Home Manager module: sops-nix secrets for all KiroCrew hosts.
# Imported on every KiroCrew output (VM, EC2, AMI) but only ACTIVATES
# where the age private key exists at ~/.config/sops/age/keys.txt.
# If absent, sops-nix logs a warning and skips decryption — the gateway
# falls back to the SSH agent socket (workstation) or fails gracefully.
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

    secrets.git-ssh-key = {
      # %r is replaced with $XDG_RUNTIME_DIR at runtime
      path = "%r/secrets/git-ssh-key";
    };
  };
}
