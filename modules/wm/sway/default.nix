{ config, pkgs, lib, powerlineLib ? null, ... }:

let
  terminal = "foot"; # Change to "foot" or other terminal
in
{
  fonts.fontconfig.enable = true;
  
  home.packages = with pkgs; [
    # sway - install via DNF instead
    swaybg
    alacritty
    dmenu
    kanshi
    rofi
    brightnessctl
    swayidle
    
    # Workspace management
    (python3.withPackages (ps: [ ps.i3ipc ]))
    sov
    
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
    
    # Swaymsg workspace switcher
    (writeShellScriptBin "swaymsg_workspace" ''
      #!/usr/bin/env bash
      workspaces=$(swaymsg -t get_workspaces | jq -r '.[] | "\(.num) \(.name) [\(.output)]"')
      selected=$(echo "$workspaces" | rofi -dmenu -p "Workspace:" | awk '{print $1}')
      [ -n "$selected" ] && swaymsg workspace number "$selected"
    '')
    
    # Screenshot menu script
    (writeShellScriptBin "screenshot-menu" ''
      #!/usr/bin/env bash
      
      # Screenshot options
      options="📷 Full Screen\n🖱️ Select Area\n📋 Full Screen (Clipboard Only)\n✂️ Select Area (Clipboard Only)"
      
      # Show menu and get selection
      selected=$(echo -e "$options" | rofi -dmenu -p 'Screenshot Mode:')
      
      # Handle selection
      case "$selected" in
        "📷 Full Screen")
          mkdir -p ~/Pictures
          file=~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png
          wayshot -f "$file" && wayshot --stdout | wl-copy
          notify-send "Screenshot" "Saved to $file and copied to clipboard"
          ;;
        "🖱️ Select Area")
          mkdir -p ~/Pictures
          file=~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png
          geometry=$(slurp) && wayshot -s "$geometry" -f "$file" && wayshot -s "$geometry" --stdout | wl-copy
          notify-send "Screenshot" "Area saved to $file and copied to clipboard"
          ;;
        "📋 Full Screen (Clipboard Only)")
          wayshot --stdout | wl-copy
          notify-send "Screenshot" "Full screen copied to clipboard"
          ;;
        "✂️ Select Area (Clipboard Only)")
          geometry=$(slurp) && wayshot -s "$geometry" --stdout | wl-copy
          notify-send "Screenshot" "Selected area copied to clipboard"
          ;;
      esac
    '')
    
    # Kanshi menu script for waybar
    (writeShellScriptBin "kanshi-menu" ''
      #!/usr/bin/env bash

      # Get available profiles
      profiles=$(grep "profile " ~/.config/kanshi/config 2>/dev/null | awk '{print $2}' | tr -d '{' || echo -e "laptop\nhome")

      # Add auto option and show menu
      selected=$(echo -e "$profiles\nauto" | rofi -dmenu -p 'Display Profile:')

      # Handle selection
      if [ "$selected" = "auto" ]; then
          systemctl --user restart kanshi
      elif [ -n "$selected" ]; then
          kanshi -p "$selected" &
      fi
    '')
  ];

  programs = {
    zellij = (import ../../desktop/zellij.nix { inherit pkgs; });
    
    foot = {
      enable = true;
      settings = {
        main = {
          shell = "/home/orre/.nix-profile/bin/zsh";
          login-shell = "yes";
          font = "monospace:size=12";
        };
        csd = {
          preferred = "none";
        };
        environment = {
          PATH = "/home/orre/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
        };
      };
    };
  };

  # Copy swaysome script
  xdg.configFile."sway/swaysome.py" = {
    source = ./swaysome.py;
    executable = true;
  };

  # Sway configuration
  xdg.configFile."sway/config".text = ''
    # Sway config
    set $mod Mod4
    
    # Prevent workspaces from jumping between displays
    workspace_auto_back_and_forth no
    
    # Set desktop environment properly for applications
    exec systemctl --user set-environment XDG_CURRENT_DESKTOP=sway
    exec systemctl --user set-environment XDG_SESSION_DESKTOP=sway
    exec systemctl --user import-environment WAYLAND_DISPLAY
    
    # Start gnome-keyring and set environment variables
    exec eval $(gnome-keyring-daemon --start --components=secrets,ssh)
    exec systemctl --user import-environment SSH_AUTH_SOCK GNOME_KEYRING_CONTROL
    
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
    bindsym $mod+Return exec env WAYLAND_DISPLAY=wayland-1 ~/.nix-profile/bin/${terminal}

    # Kill focused window
    bindsym $mod+Shift+q kill

    # Start rofi (a program launcher)
    bindsym $mod+d exec ~/.nix-profile/bin/rofi -show drun
    
    # Workspace switcher
    bindsym $mod+Tab exec ~/.nix-profile/bin/swaymsg_workspace
    
    # Workspace overview
    bindsym $mod+grave exec pkill -SIGUSR1 sov
    
    # Create new workspace on current display
    bindsym $mod+n exec ~/.nix-profile/bin/sway-new-workspace
    
    # Brightness controls
    bindsym F5 exec ~/.nix-profile/bin/brightnessctl set 5%-
    bindsym F6 exec ~/.nix-profile/bin/brightnessctl set +5%
    
    # Monitor configuration menu
    bindsym $mod+F8 exec ~/.nix-profile/bin/kanshi-menu
    
    # Lock screen
    bindsym $mod+Escape exec swaylock -c 000000

    # Change focus
    bindsym $mod+h focus left
    bindsym $mod+j focus down
    bindsym $mod+k focus up
    bindsym $mod+l focus right

    # Move focused window
    bindsym $mod+Shift+h move left
    bindsym $mod+Shift+j move down
    bindsym $mod+Shift+k move up
    bindsym $mod+Shift+l move right

    # Layout controls
    bindsym $mod+e layout toggle split
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+t layout toggle all
    
    # Create new tabbed container to the right
    bindsym $mod+Shift+t splith; layout tabbed

    # Focus outputs (displays)
    bindsym $mod+Ctrl+1 exec python3 ~/.config/sway/swaysome.py output 1
    bindsym $mod+Ctrl+2 exec python3 ~/.config/sway/swaysome.py output 2
    bindsym $mod+Ctrl+3 exec python3 ~/.config/sway/swaysome.py output 3

    # Workspace switching (stays on current display)
    bindsym $mod+1 exec swaymsg "workspace number 1; move workspace to output current"
    bindsym $mod+2 exec swaymsg "workspace number 2; move workspace to output current"
    bindsym $mod+3 exec swaymsg "workspace number 3; move workspace to output current"
    bindsym $mod+4 exec swaymsg "workspace number 4; move workspace to output current"
    bindsym $mod+5 exec swaymsg "workspace number 5; move workspace to output current"
    bindsym $mod+6 exec swaymsg "workspace number 6; move workspace to output current"
    bindsym $mod+7 exec swaymsg "workspace number 7; move workspace to output current"
    bindsym $mod+8 exec swaymsg "workspace number 8; move workspace to output current"
    bindsym $mod+9 exec swaymsg "workspace number 9; move workspace to output current"
    bindsym $mod+0 exec swaymsg "workspace number 10; move workspace to output current"

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

    # Move workspace between monitors
    bindsym $mod+Ctrl+h move workspace to output left
    bindsym $mod+Ctrl+l move workspace to output right
    bindsym $mod+Ctrl+k move workspace to output down
    bindsym $mod+Ctrl+j move workspace to output up

    # Reload the configuration file
    bindsym $mod+Shift+c reload

    # Exit sway (logs you out of your Wayland session)
    bindsym $mod+Shift+e exit

    # Set wallpaper (requires swaybg)
    exec_always ~/.nix-profile/bin/swaybg -i /usr/share/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png -m fill
    
    # Start applications on startup
    exec ~/.nix-profile/bin/${terminal}
    exec ~/.nix-profile/bin/waybar
    exec 1password --silent
    exec sov
    
    # Idle management - lock after 10 minutes, sleep after 15 minutes
    exec ~/.nix-profile/bin/swayidle -w \
        timeout 600 '~/.nix-profile/bin/swaylock -c 000000' \
        timeout 900 'swaymsg "output * dpms off"' \
        resume 'swaymsg "output * dpms on"' \
        before-sleep '~/.nix-profile/bin/swaylock -c 000000'
  '';

  # Kanshi configuration using raw config
  xdg.configFile."kanshi/config".text = ''
    output "Lenovo Group Limited 0x403A Unknown" {
      mode 1920x1200
      alias $LAPTOP
    }

    output "LG Electronics 27GL850 912NTRL9A022" {
      mode 2560x1440
      alias $LG
    }

    output "Samsung Electric Company SMS27A650 Unknown" {
      mode 1920x1080
      alias $SAMSUNG
    }

    output "BNQ BenQ GL2706PQ E9G03141SL0" {
      mode 2560x1440
      alias $BenqOffice
    }
    output "Lenovo Group Limited G27q-30 UMB6HX30" {
      mode 2560x1440
      alias $LenovoOffice
    }
    profile laptop {
      output $LAPTOP enable
    }
   

    profile home {
      output $LAPTOP enable position 2560,0
      output $LG enable position 0,0
    }
    profile portable {
      output $LAPTOP enable position 0,0
      output DP-1 enable position 1920,0
    }

    profile triple {
      output $LAPTOP enable position 0,0
      output $LG enable position 1920,0
      output $SAMSUNG enable position 4480,0 transform 90
      exec swaymsg workspace 1
      exec swaymsg move workspace to output eDP-1
      exec swaymsg workspace 2
      exec swaymsg move workspace to output DP-8
      exec swaymsg workspace 3
      exec swaymsg move workspace to output DP-10
    }
    profile tripleOffice {
      output DP-10 enable position 0,0 transform 90
      output DP-8 enable position 1440,0
      output eDP-1 enable position 4000,0
    }
  '';

  # Enable kanshi service
  services.kanshi.enable = true;

  

  



  imports = [
    (import ../../desktop/waybar/waybar.nix { inherit config pkgs lib powerlineLib; })
  ];
}
