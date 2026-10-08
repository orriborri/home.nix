{
  config,
  pkgs,
  lib,
  ...
}:

# Weekly `git worktree prune` over the repos in config/repos.toml for this
# role. Agent sessions (Claude, Codex, Kiro) delete worktree directories
# without `git worktree remove`, leaving stale entries in .git/worktrees that
# keep their branches checked out. Prune only drops entries whose directory is
# gone; it never deletes a worktree that still exists.
let
  inherit (config.kirocrew) role;
  repos = builtins.filter (
    r:
    builtins.elem role (
      r.targets or [
        "workstation"
        "headless"
      ]
    )
  ) (builtins.fromTOML (builtins.readFile ./config/repos.toml)).repos;
  prune = pkgs.writeShellApplication {
    name = "git-worktree-prune";
    runtimeInputs = [ pkgs.git ];
    text = ''
      for repo in ${lib.escapeShellArgs (map (r: r.path) repos)}; do
        dir="$HOME/$repo"
        [ -e "$dir/.git" ] || continue
        git -C "$dir" worktree prune --verbose "$@" || echo "warning: worktree prune failed in $dir" >&2
      done
    '';
  };
in
{
  systemd.user = lib.mkIf config.kirocrew.enable {
    services.git-worktree-prune = {
      Unit.Description = "Prune stale git worktree entries in manifest repos";
      Service = {
        Type = "oneshot";
        ExecStart = "${prune}/bin/git-worktree-prune";
      };
    };
    timers.git-worktree-prune = {
      Unit.Description = "Weekly git worktree prune";
      Timer = {
        OnCalendar = "weekly";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
