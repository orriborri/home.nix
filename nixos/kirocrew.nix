{
  config,
  lib,
  pkgs,
  ...
}:

# Reusable NixOS module: KiroCrew system-level dependencies.
#
# On headless/EC2 hosts, the gateway runs as a system service under the
# dedicated kirocrew user (see kirocrew-services.nix). On workstations,
# it runs as a Home Manager user service under the operator user.
#
# This module provides source-build dependencies, the kiro-cli symlink,
# and the glab symlink that all profiles need.
{
  # Allow unfree kiro packages at the system level (activation script references them)
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "kiro-cli"
      "kiro-cli-unwrapped"
    ];

  # ── Dependencies ───────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    python313 # KiroCrew currently supports CPython 3.10-3.13
    nodejs_22
    git
    gnumake # KiroCrew source releases are built with `make build`
    glab # GitLab CLI — also symlinked for gateway at /usr/local/libexec/kirocrew/
    curl
    openssl # needed by the KiroCrew installer for manifest verification
    stdenv.cc.cc.lib # libstdc++.so.6 — needed by KiroCrew's embedded llama.cpp
  ];

  # ── Symlink kiro-cli for both operator and kirocrew users ──────────────────
  # Use the unwrapped binary (no bwrap FHS sandbox) because some EC2/Amazon
  # virtualization environments block mount(/, MS_SLAVE) which bwrap requires.
  # KiroCrew strict sandbox uses Linux namespaces instead.
  system.activationScripts.kirocrew-kiro-cli-link = lib.stringAfter [ "users" ] ''
    # Operator user (workstation profiles and admin access)
    mkdir -p /home/orre/.local/bin
    chown orre:users /home/orre/.local/bin
    ln -sf ${pkgs.kiro-cli.passthru.unwrapped}/bin/kiro-cli /home/orre/.local/bin/kiro-cli

    # Dedicated kirocrew user (headless/EC2 system service)
    if id kirocrew &>/dev/null; then
      mkdir -p /var/lib/kirocrew/bin
      chown kirocrew:kirocrew /var/lib/kirocrew/bin
      ln -sf ${pkgs.kiro-cli.passthru.unwrapped}/bin/kiro-cli /var/lib/kirocrew/bin/kiro-cli
    fi
  '';

  # ── Enable lingering for operator user service (workstation profiles) ──────
  users.users.orre.linger = true;

  # ── Install glab where the KiroCrew gateway can find it (root-owned) ───────
  # The gateway rejects Nix store binaries (owned by nobody/65534) but trusts
  # root-owned files. Using a symlink to the Nix store path ensures no version
  # drift between the user-level and system-level glab.
  system.activationScripts.kirocrew-glab = lib.stringAfter [ "users" ] ''
    mkdir -p /usr/local/libexec/kirocrew
    ln -sf ${pkgs.glab}/bin/glab /usr/local/libexec/kirocrew/glab
  '';

  # ── LD_LIBRARY_PATH for libstdc++ (system-wide shellInit) ──────────────────
  environment.shellInit = ''
    export PATH="/home/orre/.local/bin:$PATH"
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:''${LD_LIBRARY_PATH:-}"
  '';
}
