{ pkgs, ... }:

{
  programs = {
    neovim = (import ./neovim.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs; });
    gitui = (import ./gitui.nix { inherit pkgs; });
  };

  home.packages = with pkgs; [
    # Programming languages
    nodejs_latest
    nodePackages.pnpm
    
    # Development tools
    tokei
    jq
    xh
    pre-commit
    uv
    
    # Audio
    pulsemixer
    
    # Shell
    zsh
    
    # Nix tools
    nil
    nixd
    
    # Build tools
    cmake
    meson
    cpio
  ];
}