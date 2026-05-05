{ config, pkgs, lib, ... }:

{
  # Utility packages organized by category
  home.packages = with pkgs; [
    # Core utilities (cross-platform)
    less
    
    # Time tracking
    timewarrior
    taskwarrior3
    taskwarrior-tui
    
    # File utilities
    fd              # Better find
    skim            # Fuzzy finder
    ncdu            # Disk usage analyzer
    dust            # Better du
    dua             # Disk usage analyzer
    ripgrep         # Better grep
    
    # Text processing
    jc              # Convert command output to JSON
    gnused          # GNU sed
    gawk            # GNU awk
    
    # System utilities
    bottom          # Better top
    jless           # JSON viewer
    navi            # Interactive cheatsheet
    tealdeer        # Better man pages
    fend            # Calculator
    
    # Clipboard and screenshot utilities (Linux only)
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    xclip
    wl-clipboard
    wayshot
    slurp
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    # macOS specific utilities
    pbcopy
    pbpaste
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    # Network utilities (Linux only)
    bluetui
    bandwhich
  ];
  
  # Shell aliases for utilities (using mkDefault to allow override)
  home.shellAliases = lib.mkDefault {
    cat = "bat";
    ls = "lsd";
    find = "fd";
    grep = "rg";
    du = "dust";
    top = "btm";
    htop = "btm";
    gwt = "lazyworktree";
  };
}
