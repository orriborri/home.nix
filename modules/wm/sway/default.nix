{ config, pkgs, lib, powerlineLib ? null, ... }:
{
  fonts.fontconfig.enable = true;
  
  home.packages = with pkgs; [
    # sway - install via DNF instead
    swaybg
    alacritty
    dmenu
    kanshi
    wofi
    brightnessctl
    
    # Custom script for new workspace on current display
    (writeShellScriptBin "sway-new-workspace" ''
      current_output=$(swaymsg -t get_workspaces | jq -r '.[] | select(.focused==true) | .output')
      used=$(swaymsg -t get_workspaces | jq -r --arg output "$current_output" '.[] | select(.output==$output) | .num')
      
      for i in $(seq 1 20); do
        if ! echo "$used" | grep -q "^$i$"; then
          swaymsg workspace number $i
          exit
        fi
      done
    '')
  ];

  programs = {
    zellij = (import ../../desktop/zellij.nix { inherit pkgs; });
    
    foot = {
      enable = true;
      settings = {
        main = {
          shell = "zsh";
        };
        csd = {
          preferred = "none";
        };
      };
    };
  };

  # Sway configuration
  xdg.configFile."sway/config".text = ''
    # Sway config
    set $mod Mod4
    
    # Set desktop environment properly for applications
    exec systemctl --user set-environment XDG_CURRENT_DESKTOP=sway
    exec systemctl --user set-environment XDG_SESSION_DESKTOP=sway
    exec systemctl --user import-environment WAYLAND_DISPLAY
    
    # Remove titlebars but keep 1px border for window delimitation
    default_border none
    default_floating_border none
    for_window [class=".*"] border pixel 1
    
    # Input configuration - Finnish keyboard layout
    input "1:1:AT_Translated_Set_2_keyboard" xkb_layout fi
    input type:keyboard xkb_layout fi

    # Touchpad configuration
    input type:touchpad {
        tap enabled
        natural_scroll enabled
        dwt enabled
        accel_profile "adaptive"
        click_method clickfinger
    }

    # Start a terminal
    bindsym $mod+Return exec foot

    # Kill focused window
    bindsym $mod+Shift+q kill

    # Start wofi (a program launcher)
    bindsym $mod+d exec wofi --show drun
    
    # Create new workspace on current display
    bindsym $mod+n exec sway-new-workspace
    
    # Brightness controls
    bindsym F5 exec brightnessctl set 5%-
    bindsym F6 exec brightnessctl set +5%

    # Change focus
    bindsym $mod+j focus left
    bindsym $mod+k focus down
    bindsym $mod+l focus up
    bindsym $mod+semicolon focus right

    # Move focused window
    bindsym $mod+Shift+j move left
    bindsym $mod+Shift+k move down
    bindsym $mod+Shift+l move up
    bindsym $mod+Shift+semicolon move right

    # Workspace switching
    bindsym $mod+1 workspace number 1
    bindsym $mod+2 workspace number 2
    bindsym $mod+3 workspace number 3
    bindsym $mod+4 workspace number 4
    bindsym $mod+5 workspace number 5
    bindsym $mod+6 workspace number 6
    bindsym $mod+7 workspace number 7
    bindsym $mod+8 workspace number 8
    bindsym $mod+9 workspace number 9
    bindsym $mod+0 workspace number 10

    # Assign workspaces to specific outputs
    workspace 1 output eDP-1
    workspace 2 output eDP-1
    workspace 3 output DP-3
    workspace 4 output DP-3
    workspace 5 output DP-3
    workspace 6 output DP-5
    workspace 7 output DP-5
    workspace 8 output DP-5
    workspace 9 output eDP-1
    workspace 10 output eDP-1

    # Move container to workspace
    bindsym $mod+Shift+1 move container to workspace number 1
    bindsym $mod+Shift+2 move container to workspace number 2
    bindsym $mod+Shift+3 move container to workspace number 3
    bindsym $mod+Shift+4 move container to workspace number 4
    bindsym $mod+Shift+5 move container to workspace number 5
    bindsym $mod+Shift+6 move container to workspace number 6
    bindsym $mod+Shift+7 move container to workspace number 7
    bindsym $mod+Shift+8 move container to workspace number 8
    bindsym $mod+Shift+9 move container to workspace number 9
    bindsym $mod+Shift+0 move container to workspace number 10

    # Reload the configuration file
    bindsym $mod+Shift+c reload

    # Exit sway (logs you out of your Wayland session)
    bindsym $mod+Shift+e exit

    # Set wallpaper (requires swaybg)
    exec_always swaybg -i /usr/share/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png -m fill
    
    # Start applications on startup
    exec foot
    exec waybar
    exec 1password --silent
  '';

  # Kanshi service for display management
  services.kanshi = {
    enable = true;
    systemdTarget = "sway-session.target";
    
    settings = [
      {
        profile.name = "laptop";
        profile.outputs = [
          {
            criteria = "eDP-1";
            status = "enable";
            mode = "1920x1080";
            scale = 1.0;
          }
        ];
      }
      {
        profile.name = "home";
        profile.outputs = [
          {
            criteria = "eDP-1";
            status = "enable";
            mode = "1920x1080";
            position = "-1920,0";
            scale = 1.0;
          }
          {
            criteria = "DP-3";
            status = "enable";
            mode = "2560x1440@59.951Hz";
            position = "0,0";
          }
        ];
      }
      {
        profile.name = "samsung-monitor";
        profile.outputs = [
          {
            criteria = "eDP-1";
            status = "enable";
            mode = "1920x1080";
            position = "0,1080";
            scale = 1.0;
          }
          {
            criteria = "DP-5";
            status = "enable";
            mode = "1920x1080";
            position = "0,0";
          }
        ];
      }
      {
        profile.name = "triple";
        profile.outputs = [
          {
            criteria = "eDP-1";
            status = "enable";
            mode = "1920x1080";
            position = "0,0";
            scale = 1.0;
          }
          {
            criteria = "DP-3";
            status = "enable";
            mode = "2560x1440";
            position = "3840,0";
          }
          {
            criteria = "DP-5";
            status = "enable";
            mode = "1920x1080";
            position = "1920,0";
          }
        ];
      }
    ];
  };

  # Create individual kanshi config files for manual switching
  xdg.configFile."kanshi/laptop.conf".text = ''
    profile laptop {
      output "eDP-1" enable mode 1920x1080 scale 1.000000
    }
  '';

  xdg.configFile."kanshi/lg-monitor.conf".text = ''
    profile lg-monitor {
      output "eDP-1" enable mode 1920x1080 position 0,1440 scale 1.000000
      output "LG Electronics 27GL850" enable mode 2560x1440 position 0,0
    }
  '';

  xdg.configFile."kanshi/samsung-monitor.conf".text = ''
    profile samsung-monitor {
      output "eDP-1" enable mode 1920x1080 position 0,1080 scale 1.000000
      output "Samsung Electric Company SMS27A650" enable mode 1920x1080 position 0,0
    }
  '';

  xdg.configFile."kanshi/triple.conf".text = ''
    profile triple {
      output "eDP-1" enable mode 1920x1080 position 2560,360 scale 1.000000
      output "LG Electronics 27GL850" enable mode 2560x1440 position 0,0
      output "Samsung Electric Company SMS27A650" enable mode 1920x1080 position 4480,360
    }
  '';

  # Create a kanshi profile switcher script
  xdg.configFile."kanshi/switch-profile.sh" = {
    text = ''
      #!/bin/bash
      PROFILE="$1"
      KANSHI_CONFIG="$HOME/.config/kanshi/config"
      
      if [ -z "$PROFILE" ]; then
        echo "Available profiles:"
        grep 'profile ' "$KANSHI_CONFIG" | awk '{print $2}' | grep -v '{' | sort -u
        exit 1
      fi
      
      if [ "$PROFILE" = "auto" ]; then
        systemctl --user restart kanshi
        echo "Restarted kanshi for automatic profile detection"
        exit 0
      fi
      
      # Create a temporary config with only the selected profile
      TEMP_CONFIG="/tmp/kanshi-$PROFILE.conf"
      
      # Extract the specific profile from the main config
      awk "/profile $PROFILE {/,/^}/" "$KANSHI_CONFIG" > "$TEMP_CONFIG"
      
      if [ ! -s "$TEMP_CONFIG" ]; then
        echo "Profile '$PROFILE' not found"
        rm -f "$TEMP_CONFIG"
        exit 1
      fi
      
      # Stop current kanshi and start with the specific profile
      systemctl --user stop kanshi
      sleep 0.5
      kanshi -c "$TEMP_CONFIG" &
      
      echo "Switched to profile: $PROFILE"
    '';
    executable = true;
  };

  # Remove the old xdg.configFile kanshi config since we're using the service now

  imports = [
    (import ../../desktop/waybar/waybar.nix { inherit config pkgs lib powerlineLib; })
  ];
}
