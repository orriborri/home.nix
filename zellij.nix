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

    # Backspace can arrive as Ctrl-h (^H) in some terminals, which Zellij
    # treats as Move mode. Unbind it in all modes so Backspace passes through.
    keybinds = {
      unbind = "Ctrl h";
    };
    ui = {
      pane_frames = {
        hide_session_name = true;
      };
    };
  };
}
