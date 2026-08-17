{ pkgs, pkgs-stable ? pkgs, ... }:

{
  # Development packages organized by category
  home.packages = with pkgs; [
    # Programming languages
    nodejs_latest
    pnpm
    python3        # Python interpreter
    pipx           # Install Python apps in isolated environments
    
    # Development tools
    openssh        # SSH client (needed by git for SSH remotes + 1Password agent)
    curl           # HTTP client (CLI)
    openssl        # TLS/SSL toolkit
    tokei          # Code statistics
    jq             # JSON processor
    xh             # HTTP client
    pre-commit     # Git hooks
    lazyworktree   # Git worktree TUI
    glab           # GitLab CLI
    uv             # Python package manager
    
    # Nix development tools
    nix            # Nix CLI (nix-shell, nix-build, nix develop, etc.)
    nil            # Nix LSP
    nixd           # Alternative Nix LSP
    nixfmt         # Nix formatter (updated from nixfmt-rfc-style)
    
    # Shell utilities
    zsh

    # AI coding tools

    # AWS tools
    ssm-session-manager-plugin  # SSM tunnel for kirocrew EC2 instance
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
