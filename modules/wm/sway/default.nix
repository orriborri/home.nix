{ config, pkgs, lib, powerlineLib ? null, ... }:

let
  terminal = "foot";
  modifier = "Mod4";
  
  # Key bindings configuration
  keybindings = {
    # Application shortcuts
    "${modifier}+Return" = "exec env WAYLAND_DISPLAY=wayland-1 ~/.nix-profile/bin/${terminal}";
    "${modifier}+d" = "exec ~/.nix-profile/bin/rofi -show drun";
    "${modifier}+Shift+q" = "kill";
    
    # Workspace management
    "${modifier}+Tab" = "exec ~/.nix-profile/bin/swaymsg_workspace";
    "${modifier}+grave" = "exec pkill -SIGUSR1 sov";
    "${modifier}+n" = "exec ~/.nix-profile/bin/sway-new-workspace";
    
    # System controls
    "${modifier}+Escape" = "exec /usr/bin/swaylock -c 000000";
    "F5" = "exec ~/.nix-profile/bin/brightnessctl set 5%-";
    "F6" = "exec ~/.nix-profile/bin/brightnessctl set +5%";
    "${modifier}+F8" = "exec ~/.nix-profile/bin/kanshi-menu";
    
    # Screenshots
    "Print" = "exec ~/.nix-profile/bin/screenshot-menu";
    "${modifier}+Print" = "exec ~/.nix-profile/bin/wayshot --stdout | wl-copy";
    "${modifier}+Shift+Print" = "exec ~/.nix-profile/bin/slurp | xargs -I {} ~/.nix-profile/bin/wayshot -s {} --stdout | wl-copy";
    
    # Window management
    "${modifier}+h" = "focus left";
    "${modifier}+j" = "focus down";
    "${modifier}+k" = "focus up";
    "${modifier}+l" = "focus right";
    
    "${modifier}+Shift+h" = "move left";
    "${modifier}+Shift+j" = "move down";
    "${modifier}+Shift+k" = "move up";
    "${modifier}+Shift+l" = "move right";
    
    # Layout controls
    "${modifier}+e" = "layout toggle split";
    "${modifier}+s" = "layout stacking";
    "${modifier}+w" = "layout tabbed";
    "${modifier}+t" = "layout toggle all";
    "${modifier}+Shift+t" = "splith; layout tabbed";
    
    # System controls
    "${modifier}+Shift+c" = "reload";
    "${modifier}+Shift+e" = "exit";
    
    # Workspace organization
    "${modifier}+Shift+o" = "exec ~/.nix-profile/bin/organize-workspaces";
    "${modifier}+Shift+a" = "exec ~/.nix-profile/bin/assign-workspace-to-display";
  };
  
  # Generate workspace bindings
  workspaceBindings = lib.listToAttrs (
    lib.flatten (
      map (i: [
        {
          name = "${modifier}+${toString i}";
          value = "exec swaymsg \"workspace number ${toString i}; move workspace to output current\"";
        }
        {
          name = "${modifier}+Shift+${toString i}";
          value = "move container to workspace number ${toString i}";
        }
      ]) (lib.range 1 9) ++ [
        {
          name = "${modifier}+0";
          value = "exec swaymsg \"workspace number 10; move workspace to output current\"";
        }
        {
          name = "${modifier}+Shift+0";
          value = "move container to workspace number 10";
        }
      ]
    )
  );
  
  # Output focus bindings
  outputBindings = {
    "${modifier}+Ctrl+1" = "exec python3 ~/.config/sway/swaysome.py output 1";
    "${modifier}+Ctrl+2" = "exec python3 ~/.config/sway/swaysome.py output 2";
    "${modifier}+Ctrl+3" = "exec python3 ~/.config/sway/swaysome.py output 3";
    
    "${modifier}+Ctrl+h" = "move workspace to output left";
    "${modifier}+Ctrl+l" = "move workspace to output right";
    "${modifier}+Ctrl+k" = "move workspace to output down";
    "${modifier}+Ctrl+j" = "move workspace to output up";
  };
  
  # Combine all bindings
  allBindings = keybindings // workspaceBindings // outputBindings;
  
  # Sway configuration
  swayConfig = {
    config = {
      modifier = modifier;
      terminal = terminal;
      
      # Input configuration
      input = {
        "1:1:AT_Translated_Set_2_keyboard" = {
          xkb_layout = "fi";
        };
        "type:keyboard" = {
          xkb_layout = "fi";
        };
        "type:touchpad" = {
          tap = "enabled";
          natural_scroll = "enabled";
          dwt = "enabled";
          accel_profile = "adaptive";
          click_method = "clickfinger";
        };
      };
      
      # Window configuration
      window = {
        border = 1;
        hideEdgeBorders = "none";
      };
      
      # Startup applications
      startup = [
        { command = "~/.nix-profile/bin/${terminal}"; }
        { command = "1password --silent"; }
        { command = "sov"; }
        { 
          command = "~/.nix-profile/bin/swayidle -w timeout 600 '/usr/bin/swaylock -c 000000' timeout 900 'swaymsg \"output * dpms off\"' resume 'swaymsg \"output * dpms on\"' before-sleep '/usr/bin/swaylock -c 000000'";
          always = true;
        }
        {
          command = "~/.nix-profile/bin/swaybg -i /usr/share/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png -m fill";
          always = true;
        }
        {
          command = "~/.nix-profile/bin/waybar";
          always = true;
        }
      ];
      
      # Swaybar configuration
      bar = {
        position = "top";
        height = 30;
        font = "JetBrainsMono Nerd Font 12";
        
        colors = {
          background = "#222D31";
          statusline = "#FFFFFF";
          separator = "#666666";
          
          focused_workspace = {
            background = "#285577";
            border = "#4C7899";
            text = "#FFFFFF";
          };
          active_workspace = {
            background = "#5F676A";
            border = "#333333";
            text = "#FFFFFF";
          };
          inactive_workspace = {
            background = "#222D31";
            border = "#222D31";
            text = "#888888";
          };
          urgent_workspace = {
            background = "#900000";
            border = "#2F343A";
            text = "#FFFFFF";
          };
          binding_mode = {
            background = "#900000";
            border = "#2F343A";
            text = "#FFFFFF";
          };
        };
        
        status_command = "while echo \"🔋 $(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null || echo 'N/A')% | 📶 $(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2 || echo 'No WiFi') | 🕐 $(date +'%H:%M')\"; do sleep 10; done";
      };
      
      # Environment setup
      environment = {
        XDG_CURRENT_DESKTOP = "sway";
        XDG_SESSION_DESKTOP = "sway";
      };
      
      # Key bindings
      keybindings = allBindings;
      
      # Workspace configuration
      workspaceAutoBackAndForth = false;
    };
  };
in
{
  fonts.fontconfig.enable = true;
  
  home.packages = with pkgs; [
    # Sway ecosystem
    swaybg
    swayidle
    swaylock
    
    # Terminal and applications
    alacritty
    foot
    
    # Application launchers and menus
    dmenu
    rofi
    waybar
    
    # Display management
    kanshi
    brightnessctl
    
    # Workspace management
    (python3.withPackages (ps: [ ps.i3ipc ]))
    sov
    
    # Screenshot utilities
    wayshot
    slurp
    wl-clipboard
    
    # Custom scripts
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
    
    (writeShellScriptBin "swaymsg_workspace" ''
      #!/usr/bin/env bash
      workspaces=$(swaymsg -t get_workspaces | jq -r '.[] | "\(.num) \(.name) [\(.output)]"')
      selected=$(echo "$workspaces" | rofi -dmenu -p "Workspace:" | awk '{print $1}')
      [ -n "$selected" ] && swaymsg workspace number "$selected"
    '')
    
    (writeShellScriptBin "screenshot-menu" ''
      #!/usr/bin/env bash
      
      options="📷 Full Screen\n🖱️ Select Area\n📋 Full Screen (Clipboard Only)\n✂️ Select Area (Clipboard Only)"
      selected=$(echo -e "$options" | rofi -dmenu -p 'Screenshot Mode:')
      
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
    
    (writeShellScriptBin "kanshi-menu" ''
      #!/usr/bin/env bash
      profiles=$(grep "profile " ~/.config/kanshi/config 2>/dev/null | awk '{print $2}' | tr -d '{' || echo -e "laptop\nhome")
      selected=$(echo -e "$profiles\nauto" | rofi -dmenu -p 'Display Profile:')

      if [ "$selected" = "auto" ]; then
          systemctl --user restart kanshi
      elif [ -n "$selected" ]; then
          kanshi -p "$selected" &
      fi
    '')
    
    # Workspace organization script
    (writeShellScriptBin "organize-workspaces" ''
      #!/usr/bin/env bash
      
      # Get all outputs sorted by X position (left to right)
      outputs=$(swaymsg -t get_outputs | jq -r '.[] | select(.active==true) | "\(.rect.x) \(.name)"' | sort -n | awk '{print $2}')
      
      # First pass: rename all workspaces to temporary high numbers to avoid conflicts
      for ws in $(swaymsg -t get_workspaces | jq -r '.[].num' | sort -n); do
          temp_num=$((ws + 1000))
          swaymsg "rename workspace $ws to $temp_num" >/dev/null 2>&1
      done
      
      # Counter for new workspace numbers
      new_workspace_num=1
      
      # Second pass: rename from temp numbers to final numbers, ordered by output position
      for output in $outputs; do
          # Get workspaces on this output (now with temp numbers), sorted
          output_workspaces=$(swaymsg -t get_workspaces | jq -r --arg output "$output" '.[] | select(.output==$output) | .num' | sort -n)
          
          for temp_num in $output_workspaces; do
              swaymsg "rename workspace $temp_num to $new_workspace_num" >/dev/null 2>&1
              echo "Renamed workspace on $output to $new_workspace_num"
              new_workspace_num=$((new_workspace_num + 1))
          done
      done
      
      echo "Workspaces organized from left to right"
    '')
    
    # Smart workspace assignment script
    (writeShellScriptBin "assign-workspace-to-display" ''
      #!/usr/bin/env bash
      
      # Get outputs sorted by X position (left to right)
      outputs=($(swaymsg -t get_outputs | jq -r '.[] | select(.active==true) | "\(.rect.x) \(.name)"' | sort -n | awk '{print $2}'))
      
      # Calculate workspaces per display (assuming 10 workspaces total)
      total_outputs=''${#outputs[@]}
      workspaces_per_display=$((10 / total_outputs))
      
      workspace_num=1
      
      for i in "''${!outputs[@]}"; do
          output="''${outputs[$i]}"
          
          # Calculate workspace range for this display
          start_ws=$workspace_num
          if [ $i -eq $((total_outputs - 1)) ]; then
              # Last display gets remaining workspaces
              end_ws=10
          else
              end_ws=$((start_ws + workspaces_per_display - 1))
          fi
          
          echo "Display $output: workspaces $start_ws-$end_ws"
          
          # Move workspaces to this display
          for ws in $(seq $start_ws $end_ws); do
              swaymsg "workspace $ws; move workspace to output $output" >/dev/null 2>&1
          done
          
          workspace_num=$((end_ws + 1))
      done
      
      echo "Workspaces distributed across displays"
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
          font = "JetBrainsMono Nerd Font:size=12";
        };
        csd = {
          preferred = "none";
        };
        environment = {
          PATH = "/home/orre/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
        };
        colors = {
          # Dracula theme
          background = "282a36";
          foreground = "f8f8f2";
        };
      };
    };
  };

  # Copy swaysome script
  xdg.configFile."sway/swaysome.py" = {
    source = ./swaysome.py;
    executable = true;
  };

  # Structured Sway configuration
  xdg.configFile."sway/config".text = ''
    # Sway configuration generated by Home Manager
    set $mod ${swayConfig.config.modifier}
    
    # Prevent workspaces from jumping between displays
    workspace_auto_back_and_forth ${if swayConfig.config.workspaceAutoBackAndForth then "yes" else "no"}
    
    # Set desktop environment
    exec systemctl --user set-environment XDG_CURRENT_DESKTOP=sway
    exec systemctl --user set-environment XDG_SESSION_DESKTOP=sway
    exec systemctl --user import-environment WAYLAND_DISPLAY
    
    # Start gnome-keyring
    exec eval $(gnome-keyring-daemon --start --components=secrets,ssh)
    exec systemctl --user import-environment SSH_AUTH_SOCK GNOME_KEYRING_CONTROL
    
    # Window appearance
    default_border pixel ${toString swayConfig.config.window.border}
    default_floating_border pixel ${toString swayConfig.config.window.border}
    for_window [class=".*"] border pixel ${toString swayConfig.config.window.border}
    
    # Input configuration
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (device: settings:
      "input \"${device}\" {\n${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "    ${key} ${value}") settings)}\n}"
    ) swayConfig.config.input)}
    
    # Key bindings
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: command: "bindsym ${key} ${command}") swayConfig.config.keybindings)}
    
    # Startup applications
    ${lib.concatStringsSep "\n" (map (app: 
      if app.always or false then "exec_always ${app.command}" else "exec ${app.command}"
    ) swayConfig.config.startup)}
  '';

  # Kanshi configuration
  xdg.configFile."kanshi/config".text = ''
    # Display profiles
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

    # Profiles
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
   
    }
    
    profile tripleOffice {
      output DP-10 enable position 0,0 transform 90
      output DP-8 enable position 1440,0
      output eDP-1 enable position 4000,0
    }
  '';

  # Enable kanshi service
  services.kanshi.enable = true;
}
