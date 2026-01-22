{ pkgs, lib, config, ... }:

{
  # Add Kiro to PATH - installed via official script to ~/.kiro
  programs.zsh.profileExtra = lib.mkAfter ''
    # Kiro CLI
    export PATH="$HOME/.kiro/bin:$PATH"
  '';

  # Create an activation script to install Kiro if not present
  home.activation.installKiro = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "$HOME/.kiro/bin/kiro" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL https://cli.kiro.dev/install | $DRY_RUN_CMD ${pkgs.bash}/bin/bash
    fi
  '';
}
