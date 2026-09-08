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
# On EC2/headless hosts, this user service is DISABLED because the gateway
# runs as a system service under the dedicated kirocrew user instead
# (see nixos/kirocrew-services.nix). This module remains active only on
# workstation profiles where everything runs under the operator user.
#
# Sandbox is set to auto: KiroCrew v0.5.0 retired the 'strict' value (allowed
# values are now 'auto' and 'off'). 'auto' enables the namespace-based
# isolation that prevents agents from accessing operator credentials, IMDS,
# and system resources.
let
  cfg = config.kirocrew;
  skillsTools = import ./nixos/kirocrew-skills-package.nix { inherit pkgs; };
  repoManifest = builtins.fromTOML (builtins.readFile ./config/repos.toml);
  skillsRepo = lib.findFirst (repo: repo.path == "code/mattpocock-skills") null repoManifest.repos;
  syncWorkstationSkills =
    cfg.enable
    && cfg.role == "workstation"
    && builtins.elem "workstation" (
      skillsRepo.targets or [
        "workstation"
        "headless"
      ]
    );
  skillsCheckout = "${config.home.homeDirectory}/${skillsRepo.path}";
  skillsMirror = "${config.home.homeDirectory}/.local/state/kirocrew/repo-mirrors/mattpocock.git";
  workstationSkillSync = pkgs.writeShellApplication {
    name = "kirocrew-workstation-skill-sync";
    text = ''
      # This public source must work without an interactive SSH agent, even
      # when the operator normally rewrites GitHub HTTPS URLs to SSH.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0
      ${skillsTools.pinnedRepo}/bin/kirocrew-pinned-repo fetch \
        --remote ${lib.escapeShellArg skillsRepo.remote} \
        --destination ${lib.escapeShellArg skillsMirror} \
        --revision ${lib.escapeShellArg skillsRepo.revision}
      ${skillsTools.pinnedRepo}/bin/kirocrew-pinned-repo checkout \
        --remote ${lib.escapeShellArg skillsMirror} \
        --destination ${lib.escapeShellArg skillsCheckout} \
        --revision ${lib.escapeShellArg skillsRepo.revision}
      ${skillsTools.sync}/bin/kirocrew-skill-sync \
        --source ${lib.escapeShellArg "${skillsCheckout}/skills"} \
        --destination ${lib.escapeShellArg "${config.home.homeDirectory}/.kiro/crew/skills"} \
        --state ${lib.escapeShellArg "${config.home.homeDirectory}/.kiro/crew/skill-sync/mattpocock"} \
        --revision ${lib.escapeShellArg skillsRepo.revision}
    '';
  };
  # Detect whether sops-nix has the git-ssh-key secret declared.
  # The module is imported on all outputs but only activates where a key exists.
  hasSops = (config.sops.secrets or { }) ? "git-ssh-key";
  useSourceInstall = cfg.enable && cfg.role == "headless";
  pinnedSourceTag = if cfg.sourceTag == null then "" else cfg.sourceTag;
  kirocrewSourceRoot = "${config.home.homeDirectory}/.local/share/kirocrew-source";
  kirocrewTzdataVersion = "2026.3";
  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];
  # Source builder shared with the headless NixOS system service
  # (nixos/kirocrew-services.nix) so both profiles build from source
  # identically. On the workstation, `--restart` bounces the user unit.
  kirocrewSourceUpdate = import ./kirocrew-source-build.nix { inherit pkgs lib; } {
    pinnedSourceTag = pinnedSourceTag;
    restartUnit = "kirocrew.service";
    restartScope = "--user";
  };
  kirocrewExecutable =
    if useSourceInstall then
      "${kirocrewSourceRoot}/current/.venv/bin/kirocrew"
    else
      "%h/.local/bin/kirocrew";
in
{
  # KiroCrew uses an isolated Python launched with -E, so PYTHONTZPATH is
  # ignored. Keep tzdata pinned inside the pipx environment across reinstalls.
  # NOTE: The kirocrew venv was installed with backend=uv (baked into pipx
  # metadata), so we use uv directly to inject packages. pipx inject refuses to
  # override the recorded backend even with PIPX_DEFAULT_BACKEND=pip.
  # UV_NO_CONFIG prevents uv from traversing parent dirs for config files
  # (hits permission errors when activation runs as root).
  home.activation.kirocrewTzdata = lib.mkIf (!useSourceInstall) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      kirocrewPython="$HOME/.local/share/pipx/venvs/kirocrew/bin/python"
      if [ -x "$kirocrewPython" ]; then
        installedVersion="$("$kirocrewPython" -c 'from importlib.metadata import version; print(version("tzdata"))' 2>/dev/null || true)"
        if [ "$installedVersion" != "${kirocrewTzdataVersion}" ]; then
          $DRY_RUN_CMD env UV_NO_CONFIG=1 ${pkgs.uv}/bin/uv pip install --python "$kirocrewPython" "tzdata==${kirocrewTzdataVersion}"
        fi
      fi
    ''
  );

  # glab is installed system-wide by nixos/kirocrew.nix (root-owned symlink
  # at /usr/local/libexec/kirocrew/glab). No sudo needed here.

  # On headless hosts, the KiroCrew gateway runs as a system service under
  # the dedicated kirocrew user (nixos/kirocrew-services.nix). The user-level
  # service is only used on workstation profiles.
  systemd.user.services.kirocrew = lib.mkIf (cfg.role == "workstation") {
    Unit = {
      Description = "KiroCrew Gateway";
      After = [
        "network-online.target"
      ]
      ++ lib.optionals hasSops [ "sops-nix.service" ]
      ++ lib.optionals syncWorkstationSkills [ "kirocrew-skill-sync.service" ];
      Wants =
        lib.optionals hasSops [ "sops-nix.service" ]
        ++ lib.optionals syncWorkstationSkills [ "kirocrew-skill-sync.service" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre =
        lib.optionals useSourceInstall [
          "${kirocrewSourceUpdate}/bin/kirocrew-source-update"
        ]
        ++ [
          "${pkgs.coreutils}/bin/mkdir -p %t/kirocrew-tmp"
          "${kirocrewExecutable} config set --local agent.sandbox auto"
        ];
      ExecStart = "${kirocrewExecutable} gateway";
      # A first source install builds the TypeScript dashboard and Python venv.
      TimeoutStartSec = "20min";
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
        "KIROCREW_BIND=0.0.0.0"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.kirocrew-skill-sync = lib.mkIf syncWorkstationSkills {
    Unit = {
      Description = "Refresh pinned KiroCrew skill directories";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${workstationSkillSync}/bin/kirocrew-workstation-skill-sync";
      UMask = "0022";
      TimeoutStartSec = "5min";
    };
    Install.WantedBy = [ "default.target" ];
  };
  systemd.user.timers.kirocrew-skill-sync = lib.mkIf syncWorkstationSkills {
    Unit.Description = "Refresh pinned KiroCrew skills every 15 minutes";
    Timer = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "30s";
      Unit = "kirocrew-skill-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Refresh stable tags daily. New releases are built and validated alongside
  # the active one; the gateway restarts only after the atomic symlink switch.
  # On headless hosts, the system-level kirocrew-gateway service manages its
  # own installation; this user-level updater is disabled there.
  systemd.user.services.kirocrew-source-update = lib.mkIf (cfg.enable && cfg.role == "workstation") {
    Unit.Description = "Update KiroCrew source release";
    Service = {
      Type = "oneshot";
      ExecStart = "${kirocrewSourceUpdate}/bin/kirocrew-source-update --restart";
      TimeoutStartSec = "20min";
    };
  };

  systemd.user.timers.kirocrew-source-update = lib.mkIf (cfg.enable && cfg.role == "workstation") {
    Unit.Description = "Daily KiroCrew stable-tag check";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
      Unit = "kirocrew-source-update.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
