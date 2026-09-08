{ pkgs }:
{
  sync = pkgs.writeShellApplication {
    name = "kirocrew-skill-sync";
    runtimeInputs = [ pkgs.git ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./scripts/kirocrew_skill_sync.py} "$@"
    '';
  };
  pinnedRepo = pkgs.writeShellApplication {
    name = "kirocrew-pinned-repo";
    runtimeInputs = [ pkgs.git ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./scripts/kirocrew_pinned_repo.py} "$@"
    '';
  };
}
