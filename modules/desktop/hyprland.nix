{ config, pkgs, lib, ... }:
let
  # Detect if we're on NixOS or not
  isNixOS = builtins.pathExists /etc/NIXOS;
in
{
  # Install essential packages through Nix (works on any system)
  home.packages = with pkgs; [
    # Wayland essentials
    #waybar
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
    
    # Lock screen - swaylock-effects works better with Fedora PAM
    swaylock-effects
    
    # PolicyKit authentication agent
    lxqt.lxqt-policykit
    
    # Fingerprint tools
    fprintd
    gtklock 
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
      "$terminal" = "kitty";
      "$fileManager" = "nautilus";
      "$menu" = "wofi --show drun";
      
      # Monitor and workspace configuration
      source = [
        "~/.config/hypr/monitors.conf"
        "~/.config/hypr/workspaces.conf"
      ];   
      # Autostart
      exec-once = [
        "dbus-update-activation-environment --systemd --all"
        "wl-paste --type text --watch cliphist store"   # Clipboard manager daemon
        "wl-paste --type image --watch cliphist store"  # Clipboard manager for images
        "mako"  # Notification daemon
        "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent"  # PolicyKit agent
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

        "$mod, E, exec, $fileManager"
        "$mod, V, togglefloating,"
        "$mod, space, exec, $menu"
        "$mod, P, pseudo,"
        "$mod, J, togglesplit,"
        
        # Clipboard manager
        "$mod SHIFT, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy"
        
        # Emoji picker
        "$mod, period, exec, /home/orre/.nix-profile/bin/wofi-emoji"
        
        # Lock screen with swaylock (Fedora compatible)
        "CTRL ALT, L, exec, swaylock -f -c 000000"
        
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
    
    extraConfig = ''
      bind = $mod, T, exec, hyprctl dispatch layoutmsg cyclenext
      bind = $mod, M, exec, hyprctl dispatch layoutmsg swapwithmaster
    '';
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
      enable = lib.mkForce true;
    };
  };
  

  
  # nwg-panel configuration
  # xdg.configFile."nwg-panel/config".text = ''
  #   [
  #     {
  #       "name": "panel-top",
  #       "output": "",
  #       "layer": "top",
  #       "position": "top",
  #       "controls": "right",
  #       "controls-settings": {
  #         "window-width": 0,
  #         "window-height": 0,
  #         "alignment": "right",
  #         "margin": 0,
  #         "icon-size": 16,
  #         "hover-opens": false,
  #         "leave-closes": true,
  #         "click-closes": true,
  #         "css-name": "controls-window",
  #         "show-values": false,
  #         "interval": 1,
  #         "angle": 0.0,
  #         "components": [
  #           "brightness",
  #           "volume",
  #           "battery"
  #         ]
  #       },
  #       "width": "auto",
  #       "height": 30,
  #       "homogeneous": true,
  #       "margin-top": 0,
  #       "margin-bottom": 0,
  #       "padding-horizontal": 0,
  #       "padding-vertical": 0,
  #       "spacing": 4,
  #       "items-padding": 4,
  #       "icons": "",
  #       "css-name": "panel-top",
  #       "modules-left": [
  #         "hypr-workspaces"
  #       ],
  #       "modules-center": [
  #         "clock"
  #       ],
  #       "modules-right": [
  #         "controls"
  #       ]
  #     }
  #   ]
  # '';
  
  # Hyprlock configuration
  xdg.configFile."hypr/hyprlock.conf".text = ''
    general {
        disable_loading_bar = true
        grace = 2
        hide_cursor = false
        no_fade_in = false
    }
    
    background {
        monitor =
        path = screenshot
        blur_passes = 3
        blur_size = 8
    }
    
    input-field {
        monitor =
        size = 300, 60
        outline_thickness = 2
        dots_size = 0.2
        dots_spacing = 0.2
        dots_center = true
        outer_color = rgba(33, 204, 255, 1.0)
        inner_color = rgba(30, 30, 30, 1.0)
        font_color = rgba(255, 255, 255, 1.0)
        fade_on_empty = false
        placeholder_text = Enter Password
        hide_input = false
        position = 0, -120
        halign = center
        valign = center
        zindex = 10
    }
    
    label {
        monitor =
        text = cmd[update:1000] echo "$(date +"%A, %B %d")"
        color = rgba(255, 255, 255, 0.8)
        font_size = 22
        font_family = Inter
        position = 0, 300
        halign = center
        valign = center
    }
    
    label {
        monitor =
        text = cmd[update:1000] echo "$(date +"%H:%M")"
        color = rgba(255, 255, 255, 1.0)
        font_size = 95
        font_family = Inter
        position = 0, 200
        halign = center
        valign = center
    }
  '';
}
