{ pkgs, lib, config, ... }:

{
  home.packages = [ 
    pkgs.kiro       # from nixpkgs (was ./kiro-package.nix; upstream-maintained, no hash drift)
    pkgs.kiro-cli   # from nixpkgs (was ./kiro-cli-package.nix; upstream-maintained, no hash drift)
    pkgs.xdg-utils  # Required for browser-based authentication
  ];

  # Shell alias to default to current directory, run in background.
  # `command` prevents the alias from recursing into itself.
  programs.zsh.shellAliases = {
    kiro = "command kiro . > /dev/null 2>&1 &";
  };
}
