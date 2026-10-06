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
# Sandbox is set to 'off' on the workstation. KiroCrew v0.5.0 retired the
# 'strict' value (allowed values are now 'auto' and 'off').
#
# WHY 'off' AND NOT 'auto' HERE -- DOUBLE SANDBOXING:
#   'auto' makes kirocrew wrap every agent child in its OWN namespace sandbox:
#   fork -> unshare(CLONE_NEWUSER) -> write identity uid/gid map ->
#   unshare(CLONE_NEWNS) -> bind-mount empty dirs -> exec (see the module
#   docstring in kiro_crew/sandbox.py). The child it execs is kiro-cli, whose
#   ACP backend then invokes bubblewrap for its own isolation. bwrap's first
#   act is mount("/", MS_REC|MS_SLAVE), and inside kirocrew's already-unshared
#   mount namespace the kernel refuses it:
#
#     bwrap: Failed to make / slave: Operation not permitted
#
#   Every agent spawn then dies rc=1 (AcpRuntimeDead), which takes down
#   dashboard chats, suggestions, auto-titles, and crew sessions. Verified on
#   Fedora: host / IS shared and standalone bwrap succeeds (rc=0), SELinux
#   logs no denial -- the failure is purely the nesting. 'off' short-circuits
#   the backend to "none" without probing (sandbox.py: `if config_mode ==
#   "off": return "none"`), so kiro-cli's bwrap gets a clean host context and
#   remains the real isolation boundary.
#
#   TRADEOFF: kirocrew's own credential masking (hiding ~/.aws, ~/.gnupg and
#   SSH keys from the child) is implemented BY that outer namespace, so it no
#   longer applies; kiro-cli's bwrap policy governs instead. Acceptable on a
#   trusted single-user workstation. kirocrew logs a once-per-process SECURITY
#   warning in this mode (_warn_mode_off_unconfined) -- expected, not a fault.
#
#   The headless EC2 host is UNAFFECTED: it runs the gateway as a system
#   service (nixos/kirocrew-services.nix) and sets its own posture there.
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
  pinnedSourceTag = if cfg.sourceTag == null then "" else cfg.sourceTag;
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
  # The gateway unit only exists for the workstation role, where the source
  # updater timer maintains this symlink.
  kirocrewExecutable = "%h/.local/bin/kirocrew";
in
{
  # glab is installed system-wide by nixos/kirocrew.nix (root-owned symlink
  # at /usr/local/libexec/kirocrew/glab). No sudo needed here.

  # On headless hosts, the KiroCrew gateway runs as a system service under
  # the dedicated kirocrew user (nixos/kirocrew-services.nix). The user-level
  # service is only used on workstation profiles.
  systemd.user.services.kirocrew = lib.mkIf (cfg.enable && cfg.role == "workstation") {
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
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p %t/kirocrew-tmp"
        # Sandbox posture is asserted on every start so it survives upgrades
        # and manual drift. MUST be 'off' on the workstation -- see the
        # double-sandbox note in the header comment.
        "${kirocrewExecutable} config set --local agent.sandbox off"
      ];
      ExecStart = "${kirocrewExecutable} gateway";
      # Same caps as the EC2 gateway (nixos/kirocrew-services.nix): the gateway
      # has peaked at ~13.5G under concurrent member load, and an uncapped one
      # can take the whole desktop down. Percentages of physical RAM, since the
      # machines differ. The user manager delegates the memory controller here.
      MemoryHigh = "70%";
      MemoryMax = "85%";
      Restart = "always";
      RestartSec = 5;
      Environment = [
        "KIROCREW_HOME=%h/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "TMPDIR=%t/kirocrew-tmp"
        "XDG_RUNTIME_DIR=%t"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        "SSH_AUTH_SOCK=%h/.1password/agent.sock"
        "PATH=%h/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin"
        "LD_LIBRARY_PATH=${kirocrewLibraryPath}"
        "KIROCREW_BIND=127.0.0.1"
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
