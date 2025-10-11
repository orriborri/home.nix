{ config, pkgs, ... }:

{
  home.packages = [ pkgs.sway pkgs.swaybg pkgs.alacritty pkgs.dmenu pkgs.i3status ];
  
  # i3status configuration
  xdg.configFile."i3status/config".text = ''
general {
    output_format = "i3bar"
    colors = true
    interval = 5
}

order += "wireless _first_"
order += "battery all"
order += "memory"
order += "tztime local"

wireless _first_ {
    format_up = "📶 %essid"
    format_down = "📶 down"
}

battery all {
    format = "🔋 %percentage"
    format_down = "🔋 No battery"
}

memory {
    format = "🧠 %used"
}

tztime local {
    format = "🕐 %H:%M"
}
  '';
  
  xdg.configFile."sway/config".text = ''
    # Sway config
    set $mod Mod4

    # Input configuration - Finnish keyboard layout
    input "1:1:AT_Translated_Set_2_keyboard" xkb_layout fi
    
    # Fallback for any other keyboards
    input type:keyboard xkb_layout fi

    # Start a terminal
    bindsym $mod+Return exec alacritty

    # Kill focused window
    bindsym $mod+Shift+q kill

    # Start dmenu (a program launcher)
    bindsym $mod+d exec dmenu_run

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

    # Reload the configuration file
    bindsym $mod+Shift+c reload

    # Exit sway (logs you out of your Wayland session)
    bindsym $mod+Shift+e exit

    # Set wallpaper (requires swaybg)
    exec_always swaybg -i /usr/share/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png -m fill

    # Styled bar
    bar {
        font pango:JetBrains Mono 12
        position top
        height 30

        colors {
            background #222D31
            statusline #FFFFFF
            separator  #666666

            focused_workspace  #4C7899 #285577 #FFFFFF
            active_workspace   #333333 #5F676A #FFFFFF
            inactive_workspace #222D31 #222D31 #888888
            urgent_workspace   #2F343A #900000 #FFFFFF
            binding_mode       #2F343A #900000 #FFFFFF
        }

        status_command while echo "🔋 $(cat /sys/class/power_supply/BAT*/capacity)% | 🕐 $(date +'%H:%M')"; do sleep 10; done
    }
  '';
}
