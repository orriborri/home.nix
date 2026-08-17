{ config, lib, pkgs, ... }:

# Reusable NixOS module: KiroCrew system-level dependencies.
# The gateway itself runs as a home-manager user service (see home.nix / kirocrew-user-service.nix).
# This module provides system packages and the kiro-cli symlink activation.
{
  # Allow unfree kiro packages at the system level (activation script references them)
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "kiro-cli"
    "kiro-cli-unwrapped"
  ];
  # ── Dependencies ───────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    python3         # full interpreter (ensurepip needed by KiroCrew installer)
    nodejs_22
    git
    curl
    openssl        # needed by the KiroCrew installer for manifest verification
    stdenv.cc.cc.lib  # libstdc++.so.6 — needed by KiroCrew's embedded llama.cpp
    # Note: bubblewrap intentionally omitted — kiro-cli's bwrap FHS sandbox
    # fails on EC2 (mount propagation blocked); we use the unwrapped binary.
  ];

  # ── Install KiroCrew (one-time, via activation script) ─────────────────────
  system.activationScripts.kirocrew-install = lib.stringAfter [ "users" ] ''
    if ! /home/orre/.local/bin/kirocrew --version &>/dev/null 2>&1; then
      echo "Installing KiroCrew as orre (first boot)..."
      sudo -u orre ${pkgs.curl}/bin/curl -fsSL https://download.crew.kiro.dev/cli.sh | sudo -u orre ${pkgs.bash}/bin/bash
    fi
  '';

  # ── Symlink kiro-cli into a path the user service can find ─────────────────
  # Use the unwrapped binary (no bwrap FHS sandbox) because the EC2/Amazon
  # virtualization environment blocks mount(/, MS_SLAVE) which bwrap requires.
  # The kirocrew service already sets sandbox=off, so no isolation is lost.
  system.activationScripts.kirocrew-kiro-cli-link = lib.stringAfter [ "users" ] ''
    mkdir -p /home/orre/.local/bin
    chown orre:users /home/orre/.local/bin
    ln -sf ${pkgs.kiro-cli.passthru.unwrapped}/bin/kiro-cli /home/orre/.local/bin/kiro-cli
  '';

  # ── Enable lingering so the user service survives SSH disconnect ────────────
  users.users.orre.linger = true;

  # ── LD_LIBRARY_PATH for libstdc++ (system-wide shellInit) ──────────────────
  environment.shellInit = ''
    export PATH="/home/orre/.local/bin:$PATH"
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:''${LD_LIBRARY_PATH:-}"
  '';
}
