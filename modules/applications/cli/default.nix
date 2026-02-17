{ pkgs, lib, config, ... }:

{
  programs = {
    zsh = (import ./zsh.nix { inherit pkgs lib config; });
    starship = (import ./starship.nix { inherit pkgs; });
    direnv = (import ./direnv.nix { inherit pkgs; });
    zoxide = (import ./zoxide.nix { inherit pkgs; });
    carapace = (import ./carapace.nix { inherit pkgs; });
    atuin = (import ./atuin.nix { inherit pkgs; });
    neovim = (import ./neovim.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs lib; });
    gitui = (import ./gitui.nix { inherit pkgs; });
    lsd = (import ./lsd.nix { inherit pkgs; });
    htop = (import ./htop.nix { inherit pkgs; });

    # Better git diff viewer
    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        line-numbers = true;
        side-by-side = true;
        syntax-theme = "Dracula";
      };
    };

    # Fuzzy finder with shell integration
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

    # Better file manager
    yazi = {
      enable = true;
      enableZshIntegration = true;
      shellWrapperName = "yy";
    };

    # Better cat alternative
    bat = {
      enable = true;
      config = {
        theme = "TwoDark";
        style = "numbers,changes,header";
      };
    };
  };
}
