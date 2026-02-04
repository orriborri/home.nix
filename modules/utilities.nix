{ config, pkgs, lib, ... }:

{
  programs = {
    lsd = (import ./utilities/lsd.nix { inherit pkgs; });
    htop = (import ./utilities/htop.nix { inherit pkgs; });
    
    # Better file manager
    yazi = {
      enable = true;
      enableZshIntegration = true;
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

  # Utility packages organized by category
  home.packages = with pkgs; [
    # Core utilities (cross-platform)
    # (uutils-coreutils.override { prefix = ""; })  # Disabled: buggy, system coreutils work fine
    less
    
    # Time tracking
    timewarrior
    
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
    
    # Clipboard utilities (Linux only)
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    xclip
    wl-clipboard
    wayshot
    slurp
    strace
    binutils
    wdisplays
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    # macOS specific utilities
    pbcopy
    pbpaste
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    # Network utilities (Linux only)
    networkmanager
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
  };
}