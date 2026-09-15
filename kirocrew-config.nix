{
  config,
  lib,
  pkgs,
  ...
}:

# KiroCrew declarative configuration module.
# Places static, non-secret configuration files via Home Manager so they
# flow through Nix evaluation onto any target host — no repo checkout needed.
let
  cfg = config.kirocrew;
in
{
  options.kirocrew = {
    enable = lib.mkEnableOption "KiroCrew declarative configuration";
    role = lib.mkOption {
      type = lib.types.enum [
        "workstation"
        "headless"
      ];
      default = "workstation";
      description = ''
        Target host role. Controls which repos are cloned and whether
        desktop-specific configuration is applied.
        - "workstation": local desktop machine (full repo set, GUI tools)
        - "headless": EC2/VM agent host (agent-relevant repos only)
      '';
    };
    sourceTag = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "v[0-9]+\\.[0-9]+\\.[0-9]+");
      default = null;
      example = "v0.3.0";
      description = ''
        Exact stable source tag for the KiroCrew source builder. When null, the
        updater follows the newest stable tag; when set, it stays pinned to that
        immutable release while the daily check reports newer tags.

        Honoured by both roles: headless hosts build it as the gateway's
        ExecStartPre, and workstations build it on the daily source-update
        timer. Normally set from ./kirocrew-source-tag.nix so every host agrees.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Expose role as an environment variable so activation scripts can filter.
    home.sessionVariables.KIROCREW_ROLE = cfg.role;

    # Place the repo manifest at a well-known XDG path.
    # Both local activation and the EC2 launcher consume this file.
    xdg.configFile."kirocrew/repos.toml".source = ./config/repos.toml;

    # Declarative SSH known_hosts for Git forges.
    # Replaces the launcher's imperative known_hosts injection.
    # Placed as a separate file; SSH config references it via UserKnownHostsFile.
    home.file.".ssh/known_hosts_kirocrew".text = ''
      gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
      github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    '';

    # Ensure SSH reads both the standard and our declarative known_hosts files.
    programs.ssh.extraConfig = ''
      UserKnownHostsFile ~/.ssh/known_hosts ~/.ssh/known_hosts_kirocrew
    '';
  };
}
