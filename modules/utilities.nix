{ config, pkgs, ... }:

{
  programs = {
    lsd = (import ./utilities/lsd.nix { inherit pkgs; });
    htop = (import ./utilities/htop.nix { inherit pkgs; });
  };

  home.packages = with pkgs; [
    (uutils-coreutils.override { prefix = ""; })
    less
    
    # Time tracking
    timewarrior
    
    # File utilities
    fd
    skim
    ncdu
    dust
    dua
    
    # Network utilities
    networkmanager
    bluetui
    bandwhich
    
    # Text processing
    jc
    ripgrep
    igrep
    gnused
    gawk
    
    # System utilities
    xclip
    wl-clipboard
    wayshot
    slurp
    bottom
    jless
    navi
    tealdeer
    fend
    
  ] ++ (
    if pkgs.stdenv.isLinux then [
      strace
      binutils
    ] else []
  );
  
}