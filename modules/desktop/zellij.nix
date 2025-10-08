{ pkgs, ... }:

{
  enable = true;
  # enableZshIntegration = true;
  # exitShellOnExit = true;
  settings = {
    simplified_ui = true;
    theme = "catppuccin-mocha";
    default_shell = "${pkgs.zsh}/bin/zsh";
    show_startup_tips = false;
    auto_layout = true;
    viewport_serialization = false;
    session_serialization = false;
  };
}
