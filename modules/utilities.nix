{ config, pkgs, ... }:

{
  programs = {
    lsd = (import ./utilities/lsd.nix { inherit pkgs; });
    htop = (import ./utilities/htop.nix { inherit pkgs; });
  };

  home.packages = with pkgs; [
    (uutils-coreutils.override { prefix = ""; })
    less
    cmake  
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