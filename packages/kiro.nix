{ pkgs, lib, config, ... }:

let
  kiro-ide = pkgs.callPackage ./kiro-package.nix {};
  kiro-cli = pkgs.callPackage ./kiro-cli-package.nix {};
in
{
  home.packages = [ 
    kiro-ide
    kiro-cli
    pkgs.xdg-utils  # Required for browser-based authentication
  ];

  # Shell alias to default to current directory, run in background
  programs.zsh.shellAliases = {
    kiro = "kiro-ide . > /dev/null 2>&1 &";
  };
}
