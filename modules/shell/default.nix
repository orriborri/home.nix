{ pkgs, lib, config, ... }:

{
  programs = {
    zsh = (import ./zsh.nix { inherit pkgs lib config; });
    starship = (import ./starship.nix { inherit pkgs; });
    direnv = (import ./direnv.nix { inherit pkgs; });
    zoxide = (import ./zoxide.nix { inherit pkgs; });
    carapace = (import ./carapace.nix { inherit pkgs; });
    atuin = (import ./atuin.nix { inherit pkgs; });
    
    # Better fuzzy finder integration
    fzf = {
      enable = true;
      enableZshIntegration = true;
      defaultCommand = "fd --type f --hidden --follow --exclude .git";
      defaultOptions = [
        "--height 40%"
        "--layout=reverse"
        "--border"
        "--inline-info"
      ];
    };
  };
}