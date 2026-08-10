{ pkgs, lib, pkgs-stable ? pkgs, nanocoder ? null, ... }:

{
  # Development packages organized by category
  home.packages = with pkgs; [
    # Programming languages
    nodejs_latest
    pnpm
    
    # Development tools
    tokei          # Code statistics
    jq             # JSON processor
    xh             # HTTP client
    pre-commit     # Git hooks
    lazyworktree   # Git worktree TUI
    glab           # GitLab CLI
    uv             # Python package manager
    
    # Nix development tools
    nil            # Nix LSP
    nixd           # Alternative Nix LSP
    nixfmt         # Nix formatter (updated from nixfmt-rfc-style)
    
    # Shell utilities
    zsh

    # AI coding tools
  ] ++ lib.optionals (nanocoder != null) [
    nanocoder.packages.${pkgs.stdenv.system}.default
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
