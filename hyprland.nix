{ config, pkgs, lib, ... }:
let
  # Detect if we're on NixOS or not
  isNixOS = builtins.pathExists /etc/NIXOS;
in
{
  # Install essential packages through Nix (works on any system)
  home.packages = with pkgs; [
    # Wayland essentials
    waybar
    wofi
    wofi-emoji
  
    # Notification daemon
    mako
    
    # Audio/Video tools
    brightnessctl
    playerctl
    
    # Wayland utilities
    wl-clipboard
    grim
    slurp
    wev
    
    # Fonts
    font-awesome
    
    # Lock screen (swaylock-effects as alternative to hyprlock)
    
    # Monitor configuration tool
    nwg-displays
    
  ] ++ lib.optionals (!isNixOS) [
    # On non-NixOS, also install Hyprland through Nix as fallback
    # (use system package if available, Nix package as backup)
    hyprland
  ];
  
  # Configure foot terminal
  
    
  
  # Configure Hyprland through Home Manager
  wayland.windowManager.hyprland = {
    enable = true;
    package = if isNixOS then null else pkgs.hyprland; # Use system package on NixOS, Nix package elsewhere
    
    # Modern Home Manager settings configuration
    settings = {
      # Variables
      "$mod" = "SUPER";
      "$terminal" = "foot";
      "$fileManager" = "nautilus";
      "$menu" = "wofi --show drun";
      
      # Monitor configuration (managed by nwg-displays)
      # Source external monitor configuration
      source = [
        "~/.config/hypr/monitors.conf"
      ];
      
      # Workspace configuration is now handled by split-monitor-workspaces plugin
      
      # Autostart
      exec-once = [
        "waybar"
        "dbus-update-activation-environment --systemd --all"
        "wl-paste --type text --watch cliphist store"   # Clipboard manager daemon
        "wl-paste --type image --watch cliphist store"  # Clipboard manager for images
        "mako"  # Notification daemon
      ];
      
      # Environment variables
      env = [
        "XCURSOR_SIZE,24"
        "HYPRCURSOR_SIZE,24"
      ];
      
      # General settings
      general = {
        gaps_in = 1;
        gaps_out = 2;
        border_size = 1;
        "col.active_border" = "rgba(33ccffee) rgba(00ff99ee) 45deg";
        "col.inactive_border" = "rgba(595959aa)";
        resize_on_border = false;
        allow_tearing = false;
        layout = "master";
      };
      
      # Decoration
      decoration = {
        rounding = 10;
        active_opacity = 1.0;
        inactive_opacity = 1.0;
        
        shadow = {
          enabled = true;
          range = 4;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };
        
        blur = {
          enabled = true;
          size = 3;
          passes = 1;
          vibrancy = 0.1696;
        };
      };
      
      # Input
      input = {
        kb_layout = "fi";
        follow_mouse = 1;
        sensitivity = 0;
        
        touchpad = {
          natural_scroll = false;
        };
      };
      
      # Dwindle layout
      dwindle = {
        pseudotile = true;
        preserve_split = true;
      };
      
      # Master layout
      master = {
        mfact = 0.7;
      };
      
      # Keybindings
      bind = [
        # Application shortcuts
        "$mod, Q, exec, $terminal"
        "$mod, C, killactive,"
        "$mod, M, exec, hyprctl keyword general:layout master"
        "$mod, E, exec, $fileManager"
        "$mod, V, togglefloating,"
        "$mod, space, exec, $menu"
        "$mod, P, pseudo,"
        "$mod, J, togglesplit,"
        
        # Clipboard manager
        "$mod SHIFT, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy"
        
        # Emoji picker
        "$mod, period, exec, /home/orre/.nix-profile/bin/wofi-emoji"
        
        # Lock screen with swaylock-effects (more compatible than hyprlock)
        "ctrl alt, L, exec, swaylock --screenshots --clock --indicator --indicator-radius 100 --indicator-thickness 7 --effect-blur 7x5 --effect-vignette 0.5:0.5 --ring-color bb00cc --key-hl-color 880033 --line-color 00000000 --inside-color 00000088 --separator-color 00000000 --grace 2 --fade-in 0.2"
        
        # Focus movement
        "$mod, h, movefocus, l"
        "$mod, l, movefocus, r"
        "$mod, k, movefocus, u"
        "$mod, j, movefocus, d"

        # Master layout controls
        "$mod, plus, layoutmsg, mfact +0.05"
        "$mod, minus, layoutmsg, mfact -0.05"


	"$mod ctrl,h, resizeactive, -20 0"
        "$mod ctrl,l, resizeactive, 20 0"
        "$mod ctrl,k, resizeactive, 0 -20"
        "$mod ctrl,j, resizeactive, 0 20"

	"$mod shift ctrl,h, resizeactive, -100 0"
        "$mod shift ctrl,l, resizeactive, 100 0"
        "$mod shift ctrl,k, resizeactive, 0 -100"
        "$mod shift ctrl,j, resizeactive, 0 100"
       	

        # Special workspace
        "$mod, S, togglespecialworkspace, magic"
        "$mod SHIFT, S, movetoworkspace, special:magic"
      ] ++ (
        # Generate workspace bindings (1-9, 0 for workspace 10) using split-monitor-workspaces
        builtins.concatLists (builtins.genList (i:
          let 
            ws = i + 1;
            key = if ws == 10 then "0" else toString ws;
          in [
            "$mod, ${key}, workspace, ${toString ws}"
            "$mod SHIFT, ${key}, movetoworkspace, ${toString ws}"
          ]
        ) 10)
      );
      
      # Multimedia keys
      bindel = [
        ",XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ",XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ",XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ",XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ",XF86MonBrightnessUp, exec, brightnessctl s 10%+"
        ",XF86MonBrightnessDown, exec, brightnessctl s 10%-"
      ];
      
      # Media control keys
      bindl = [
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPause, exec, playerctl play-pause"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioPrev, exec, playerctl previous"
      ];
      
      # Mouse bindings
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
      
      # Window rules
      windowrulev2 = [
        "suppressevent maximize, class:.*"
      ];
    };
  };
  
  # Create desktop session file on non-NixOS systems
  home.file.".local/share/applications/hyprland-session.desktop" = lib.mkIf (!isNixOS) {
    text = ''
      [Desktop Entry]
      Name=Hyprland (Home Manager)
      Comment=Hyprland compositor managed by Home Manager
      Exec=''${config.home.homeDirectory}/.nix-profile/bin/hyprland
      Type=Application
      DesktopNames=Hyprland
    '';
  };
  
  # Environment variables for all systems
  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    
    # Graphics and Wayland environment
    WLR_NO_HARDWARE_CURSORS = "1";
    WLR_RENDERER_ALLOW_SOFTWARE = "1";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    
    # Hyprland specific - disable auto config generation
    HYPRLAND_NO_AUTOGEN = "1";
    
    # AMD specific (works on Intel/NVIDIA too)
    LIBVA_DRIVER_NAME = lib.mkDefault "radeonsi";
    VDPAU_DRIVER = lib.mkDefault "radeonsi";
  };
  
  # Configure programs that work well with Hyprland
  programs = {
    # Firefox with Wayland support
    firefox = {
      enable = true;
      package = pkgs.firefox-wayland;
    };
    
    # Waybar configuration
    waybar = {
      enable = true;
      # You can add waybar config here if needed
    };
  };
  
  # Hyprlock configuration
  xdg.configFile."hypr/hyprlock.conf".text = ''
    # Hyprlock Configuration for v0.8.2
    
    general {
        grace = 5
        hide_cursor = true
    }
    
    background {
        monitor =
        path = screenshot
        blur_passes = 3
        blur_size = 8
    }
    
    input-field {
        monitor =
        size = 200, 50
        outline_thickness = 3
        dots_size = 0.33
        dots_spacing = 0.15
        dots_center = false
        dots_rounding = -1
        outer_color = rgb(33ccff)
        inner_color = rgb(200, 200, 200)
        font_color = rgb(10, 10, 10)
        fade_on_empty = true
        fade_timeout = 1000
        placeholder_text = <i>Input Password...</i>
        hide_input = false
        rounding = -1
        check_color = rgb(204, 136, 34)
        fail_color = rgb(204, 34, 34)
        fail_text = <i>''${FAIL} <b>(''${ATTEMPTS})</b></i>
        capslock_color = -1
        numlock_color = -1
        bothlock_color = -1
        invert_numlock = false
        swap_font_color = false
        
        position = 0, -20
        halign = center
        valign = center
    }
    
    label {
        monitor =
        text = Hi there, ''${USER}
        text_align = center
        color = rgba(200, 200, 200, 1.0)
        font_size = 25
        font_family = Noto Sans
        rotate = 0
        
        position = 0, 80
        halign = center
        valign = center
    }
  '';
}
