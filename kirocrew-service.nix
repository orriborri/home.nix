{
  pkgs,
  config,
  lib,
  ...
}:

# Home-manager module: KiroCrew gateway as a systemd user service.
# Requires lingering enabled (users.users.orre.linger = true in NixOS config)
# on headless boxes; on desktop systems it starts with the graphical session.
#
# Sandbox is disabled (off) because the EC2 instance runs inside a NixOS AMI
# where bwrap's mount(/, MS_SLAVE) fails even with PrivateMounts — the mount
# propagation flags in the NixOS initrd-created rootfs prevent nested namespace
# sandboxing. The box is already a dedicated single-purpose host so OS-level
# sandbox adds no meaningful isolation beyond what NixOS + the security group
# already provide.
let
  # Detect whether sops-nix is active (EC2) or we're on a local workstation.
  hasSops = config.sops or null != null && (config.sops.secrets or { }) != { };
  kirocrewTzdataVersion = "2026.3";
  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];
in
{
  # KiroCrew uses an isolated Python launched with -E, so PYTHONTZPATH is
  # ignored. Keep tzdata pinned inside the pipx environment across reinstalls.
  # NOTE: The kirocrew venv was installed with backend=uv (baked into pipx
  # metadata), so we use uv directly to inject packages. pipx inject refuses to
  # override the recorded backend even with PIPX_DEFAULT_BACKEND=pip.
  # UV_NO_CONFIG prevents uv from traversing parent dirs for config files
  # (hits permission errors when activation runs as root).
  home.activation.kirocrewTzdata = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    kirocrewPython="$HOME/.local/share/pipx/venvs/kirocrew/bin/python"
    if [ -x "$kirocrewPython" ]; then
      installedVersion="$("$kirocrewPython" -c 'from importlib.metadata import version; print(version("tzdata"))' 2>/dev/null || true)"
      if [ "$installedVersion" != "${kirocrewTzdataVersion}" ]; then
        $DRY_RUN_CMD env UV_NO_CONFIG=1 ${pkgs.uv}/bin/uv pip install --python "$kirocrewPython" "tzdata==${kirocrewTzdataVersion}"
      fi
    fi
  '';

  # Keep glab accessible to KiroCrew's Changes panel.
  # The gateway rejects Nix store binaries (owned by nobody/65534),
  # but trusts root-owned copies in /usr/local/libexec/kirocrew/.
  home.activation.kiroCli = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GLAB_SRC="$(readlink -f /etc/profiles/per-user/orre/bin/glab 2>/dev/null || true)"
    if [ -n "$GLAB_SRC" ] && [ -f "$GLAB_SRC" ]; then
      sudo mkdir -p /usr/local/libexec/kirocrew
      sudo cp "$GLAB_SRC" /usr/local/libexec/kirocrew/glab
      sudo chmod 755 /usr/local/libexec/kirocrew/glab
    fi
  '';

  systemd.user.services.kirocrew = {
    Unit = {
      Description = "KiroCrew Gateway";
      After = [ "network-online.target" ] ++ lib.optionals hasSops [ "sops-nix.service" ];
      Wants = lib.optionals hasSops [ "sops-nix.service" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %t/kirocrew-tmp && %h/.local/bin/kirocrew config set --local agent.sandbox off";
      ExecStart = "%h/.local/bin/kirocrew gateway";
      Restart = "always";
      RestartSec = 5;
      Environment = [
        "KIROCREW_HOME=%h/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "TMPDIR=%t/kirocrew-tmp"
        "XDG_RUNTIME_DIR=%t"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        "SSH_AUTH_SOCK=%h/.1password/agent.sock"
        "PATH=%h/.local/bin:/etc/profiles/per-user/orre/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${kirocrewLibraryPath}"
      ]
      ++ lib.optionals hasSops [
        # Use the sops-decrypted SSH key for git operations (GitHub/GitLab).
        "GIT_SSH_COMMAND=ssh -i %t/secrets/git-ssh-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
