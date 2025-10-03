{ pkgs, ... }:
{
  enable = true;
  # Use the pinned packages to avoid recompilation - this will be passed from home.nix
  package = pkgs.kitty;
  
  # Settings
  settings = {
    # Shell configuration
    shell = "${pkgs.zsh}/bin/zsh";
    
    # Graphics settings for better compatibility
    linux_display_server = "wayland";
    wayland_titlebar_color = "system";
    
    # Copy/paste configuration
    copy_on_select = true;
    strip_trailing_spaces = "smart";
    
    # Font settings
    font_family = "JetBrains Mono";
    font_size = 12;
    
    # Window settings
    remember_window_size = false;
    initial_window_width = 120;
    initial_window_height = 30;
    
    # Appearance
    background_opacity = "0.95";
    window_padding_width = 8;
    
    # Cursor
    cursor_shape = "beam";
    cursor_blink_interval = 0;
    
    # Scrollback
    scrollback_lines = 10000;
    
    # Tab bar
    tab_bar_edge = "top";
    tab_bar_style = "powerline";
    
    # Performance
    repaint_delay = 10;
    input_delay = 3;
    
    # Misc
    enable_audio_bell = false;
    visual_bell_duration = "0.0";
    
    # URL handling
    open_url_with = "default";
    url_style = "curly";
    
    # Selection
    select_by_word_characters = "@-./_~?&=%+#";
  };
  
  # Key mappings
  keybindings = {
    # Copy/paste shortcuts
    "ctrl+shift+c" = "copy_to_clipboard";
    "ctrl+shift+v" = "paste_from_clipboard";
    
    # Tab management
    "ctrl+shift+t" = "new_tab";
    "ctrl+shift+w" = "close_tab";
    "ctrl+shift+right" = "next_tab";
    "ctrl+shift+left" = "previous_tab";
    
    # Window management
    "ctrl+shift+n" = "new_window";
    "ctrl+shift+q" = "close_window";
    
    # Font size
    "ctrl+shift+plus" = "increase_font_size";
    "ctrl+shift+minus" = "decrease_font_size";
    "ctrl+shift+backspace" = "restore_font_size";
    
    # Scrolling
    "ctrl+shift+up" = "scroll_line_up";
    "ctrl+shift+down" = "scroll_line_down";
    "ctrl+shift+page_up" = "scroll_page_up";
    "ctrl+shift+page_down" = "scroll_page_down";
    "ctrl+shift+home" = "scroll_home";
    "ctrl+shift+end" = "scroll_end";
  };
}