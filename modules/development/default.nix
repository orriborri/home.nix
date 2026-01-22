{ pkgs, lib, pkgs-stable ? pkgs, ... }:

{
  programs = {
    neovim = (import ./neovim.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs lib; });
    gitui = (import ./gitui.nix { inherit pkgs; });
    
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
    
    # Better directory navigation
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };

  # Development packages organized by category
  home.packages = with pkgs; [
    # Programming languages
    nodejs_latest
    nodePackages.pnpm
    
    # Development tools
    tokei          # Code statistics
    jq             # JSON processor
    xh             # HTTP client
    pre-commit     # Git hooks
    uv             # Python package manager
    
    # Nix development tools
    nil            # Nix LSP
    nixd           # Alternative Nix LSP
    nixfmt         # Nix formatter (updated from nixfmt-rfc-style)
    
    # Build tools
    cmake
    meson
    cpio
    
    # Shell utilities
    zsh
    
    # Audio (Linux only)
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    pulsemixer
  ];

  # Development environment variables
  home.sessionVariables = {
    # Development paths
    EDITOR = "nvim";
    
    # Node.js configuration
    NPM_CONFIG_PREFIX = "$HOME/.npm-packages";
    
    # Python configuration
    PYTHONPATH = "$HOME/.local/lib/python3.11/site-packages:$PYTHONPATH";
  };
}