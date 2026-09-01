{ config, ... }:

# ⚠ DRAFT — NOT YET WIRED IN. Deferred (2026-09-01).
# This module is intentionally NOT imported by any flake output yet. It is a
# starting point for a future migration where the kirocrew agent gets its own
# git credentials (goal: let the agent sign commits on the operator's behalf).
# Until that migration is picked up, the push/credential model stays as-is:
# repos are cloned as `orre` and the gateway uses orre's identity.
# Before wiring this in, revisit the push-privilege question (should kirocrew
# push directly, or should push be gated through orre?) and the commit-signing
# key design (separate signing key vs. reusing the transport key).
#
# ── Original design notes (for the future migration) ───────────────────────
# NixOS (system-level) sops-nix configuration for the dedicated `kirocrew`
# service user.
#
# On headless/EC2 hosts the gateway runs as a SYSTEM service under the
# unprivileged `kirocrew` user (see kirocrew-services.nix). That user has no
# home-manager instance and no login session, so the HM sops module
# (sops.nix, imported under home-manager.users.orre) cannot provision secrets
# for it. This module fills that gap with system-level sops-nix.
#
# Design (A1 — kirocrew owns its own key):
#   * Age private key lives in the kirocrew user's home at
#     /var/lib/kirocrew/.config/sops/age/keys.txt. It is the SAME age key
#     already tracked in .sops.yaml (1Password item "kirocrew-age"), so
#     secrets/secrets.yaml does NOT need re-encryption — only the private key
#     is bootstrapped into kirocrew's home instead of orre's.
#   * The decrypted git-ssh-key is written to a persistent path inside the
#     kirocrew home (/var/lib/kirocrew/secrets/git-ssh-key), owned by kirocrew.
#     This sits under `kirocrewHome`, which the gateway unit already lists in
#     ReadWritePaths and which ProtectHome does not mask.
#
# One-time bootstrap on the instance (documented in nixos/kirocrew.md):
#   install -d -m 700 -o kirocrew -g kirocrew /var/lib/kirocrew/.config/sops/age
#   op read "op://<vault>/kirocrew-age/private-key" \
#     | install -m 600 -o kirocrew -g kirocrew /dev/stdin \
#         /var/lib/kirocrew/.config/sops/age/keys.txt
#
# sops-install-secrets runs at activation and creates the
# sops-nix.service / sops-install-secrets.service unit that other services can
# order after.
{
  sops = {
    # System-level: decrypt using the kirocrew user's age key.
    age.keyFile = "/var/lib/kirocrew/.config/sops/age/keys.txt";
    # Do not require the key at build/eval time; only at activation. If the key
    # is absent the activation logs an error but evaluation still succeeds, so
    # the AMI/VM outputs build without the private key present.
    age.generateKey = false;

    defaultSopsFile = ../secrets/secrets.yaml;

    secrets.git-ssh-key = {
      owner = config.users.users.kirocrew.name;
      inherit (config.users.users.kirocrew) group;
      mode = "0400";
      # Persistent, inside kirocrewHome so the ProtectHome'd gateway can read it
      # and the launcher (running as kirocrew) can reference it for git over SSH.
      path = "/var/lib/kirocrew/secrets/git-ssh-key";
    };
  };
}
