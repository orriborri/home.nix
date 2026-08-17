{ pkgs, ... }:

{
  enable = true;
  settings = {
    simplified_ui = true;
    theme = "catppuccin-mocha";
    default_shell = "${pkgs.zsh}/bin/zsh";
    copy_command = "${pkgs.wl-clipboard}/bin/wl-copy";
    show_startup_tips = false;
    auto_layout = true;
    viewport_serialization = false;
    session_serialization = false;
    ui = {
      pane_frames = {
        hide_session_name = true;
      };
    };
  };
}
