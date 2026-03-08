{ pkgs, lib, config, ... }:

let
  kiro-ide = pkgs.callPackage ./kiro-package.nix {};
in
{
  home.packages = [ 
    kiro-ide
    pkgs.xdg-utils  # Required for browser-based authentication
  ];

  # Add Kiro CLI to PATH
  programs.zsh.profileExtra = lib.mkAfter ''
    # Kiro CLI
    export PATH="$HOME/.local/bin:$HOME/.kiro/bin:$PATH"
  '';
  
  # Shell alias to default to current directory, run in background
  programs.zsh.shellAliases = {
    kiro = "kiro-ide . > /dev/null 2>&1 &";
  };

  # Install Kiro CLI if not present
  home.activation.installKiroCli = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "$HOME/.local/bin/kiro-cli" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL https://cli.kiro.dev/install | $DRY_RUN_CMD ${pkgs.bash}/bin/bash
    fi
  '';
}
