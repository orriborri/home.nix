{ config, pkgs, lib, powerlineLib ? null, ... }:

let
  # Import waybar configuration
  waybarConfig = import ../../utils/waybar/waybar.nix { inherit config pkgs lib powerlineLib; };
  
  terminal = "foot";
  modifier = "Mod4";
  
  # Key bindings configuration
  keybindings = {
    # Application shortcuts
    "${modifier}+Return" = "exec env WAYLAND_DISPLAY=wayland-1 ~/.nix-profile/bin/${terminal}";
    "${modifier}+d" = "exec ~/.nix-profile/bin/wofi --show drun";
    "${modifier}+period" = "exec ~/.nix-profile/bin/wofi-emoji";
    "${modifier}+Shift+period" = "exec ~/.nix-profile/bin/gif-picker";
    "${modifier}+Shift+q" = "kill";

    # Keybinding browser
    "${modifier}+slash" = "exec ~/.nix-profile/bin/wofi-sway-keybindings";
    
    # Workspace management
    "${modifier}+Tab" = "exec ~/.nix-profile/bin/swaymsg_workspace";
    "${modifier}+grave" = "exec pkill -SIGUSR1 sov";
    "${modifier}+n" = "exec ~/.nix-profile/bin/sway-new-workspace";
    "${modifier}+r" = "exec ~/.nix-profile/bin/workspace-rename";
    
    # System controls
    "${modifier}+Escape" = "exec ~/.nix-profile/bin/swaylock -c 000000";
    "F5" = "exec ~/.nix-profile/bin/brightnessctl set 5%-";
    "F6" = "exec ~/.nix-profile/bin/brightnessctl set +5%";
    "${modifier}+F8" = "exec ~/.nix-profile/bin/display-manager";
    
    # Screenshots
    "${modifier}+p" = "exec ~/.nix-profile/bin/screenshot-menu";
    "${modifier}+Shift+p" = "exec ~/.nix-profile/bin/grim - | ~/.nix-profile/bin/wl-copy";
    "${modifier}+Ctrl+p" = "exec ~/.nix-profile/bin/grim -g \"$(~/.nix-profile/bin/slurp)\" - | ~/.nix-profile/bin/wl-copy";
    
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
      
      # Output configuration (permanent display setup)
      output = {
        "DP-10" = {
          mode = "2560x1440@59.951Hz";
          pos = "1120 0";
          transform = "270";
        };
        "DP-8" = {
          mode = "2560x1440@60Hz";
          pos = "2560 0";
        };
        "eDP-1" = {
          mode = "1920x1200@60.001Hz";
          pos = "5120 0";
        };
      };
      
      # Window configuration
      window = {
        border = 1;
        hideEdgeBorders = "none";
      };
      
      # Startup applications
      startup = [
        {
          command = "pkill mako >/dev/null 2>&1; ~/.nix-profile/bin/mako";
          always = true;
        }
        {
          command = "pkill -f 'python3 ~/.config/sway/autotab.py' >/dev/null 2>&1 || true; python3 ~/.config/sway/autotab.py";
          always = true;
        }
        { command = "~/.nix-profile/bin/${terminal}"; }
        { command = "1password --silent"; }
        { command = "sov"; }
        { 
          command = "~/.nix-profile/bin/swayidle -w timeout 600 '~/.nix-profile/bin/swaylock -c 000000' timeout 900 'swaymsg \"output * dpms off\"' resume 'swaymsg \"output * dpms on\"' before-sleep '~/.nix-profile/bin/swaylock -c 000000'";
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
    wofi
    waybar
    
    # Display management
    kanshi
    nwg-displays
    brightnessctl
    
    # Workspace management
    (python3.withPackages (ps: [ ps.i3ipc ]))
    sov
    
    # Screenshot utilities
    grim
    slurp
    wl-clipboard
    wofi-emoji
    
    # Custom scripts
    (writeShellScriptBin "sway-new-workspace" ''
      #!/usr/bin/env bash
      export PATH="$HOME/.nix-profile/bin:/usr/bin:$PATH"
      
      current_output=$(swaymsg -t get_workspaces | jq -r '.[] | select(.focused==true) | .output')
      used=$(swaymsg -t get_workspaces | jq -r '.[].num')
      
      for i in $(seq 1 20); do
        if ! echo "$used" | grep -q "^$i$"; then
          swaymsg "workspace number $i; move workspace to output $current_output"
          organize-workspaces
          exit 0
        fi
      done
    '')
    
    (writeShellScriptBin "swaymsg_workspace" ''
      #!/usr/bin/env bash
      workspaces=$(swaymsg -t get_workspaces | jq -r '.[] | "\(.num) \(.name) [\(.output)]"')
      selected=$(echo "$workspaces" | wofi --dmenu -p "Workspace:" | awk '{print $1}')
      [ -n "$selected" ] && swaymsg workspace number "$selected"
    '')
    
    (writeShellScriptBin "screenshot-menu" ''
      #!/usr/bin/env bash
      
      export PATH="$HOME/.nix-profile/bin:$PATH"
      
      options="📷 Full Screen\n🖱️ Select Area\n📋 Full Screen (Clipboard Only)\n✂️ Select Area (Clipboard Only)"
      selected=$(echo -e "$options" | wofi --dmenu -p 'Screenshot Mode:')
      
      case "$selected" in
        "📷 Full Screen")
          mkdir -p ~/Pictures
          file=~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png
          grim "$file" && grim - | wl-copy
          notify-send "Screenshot" "Saved to $file and copied to clipboard"
          ;;
        "🖱️ Select Area")
          mkdir -p ~/Pictures
          file=~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png
          geometry=$(slurp) && grim -g "$geometry" "$file" && grim -g "$geometry" - | wl-copy
          notify-send "Screenshot" "Area saved to $file and copied to clipboard"
          ;;
        "📋 Full Screen (Clipboard Only)")
          grim - | wl-copy
          notify-send "Screenshot" "Full screen copied to clipboard"
          ;;
        "✂️ Select Area (Clipboard Only)")
          geometry=$(slurp) && grim -g "$geometry" - | wl-copy
          notify-send "Screenshot" "Selected area copied to clipboard"
          ;;
      esac
    '')
    
    (writeShellScriptBin "power-menu" ''
      selected=$(echo -e "🔒 Lock\n😴 Suspend\n🔄 Reboot\n⏻ Shutdown\n🚪 Logout" | wofi -i --dmenu -p "Power:")
      case "$selected" in
        "🔒 Lock") ~/.nix-profile/bin/swaylock -c 000000 ;;
        "😴 Suspend") ~/.nix-profile/bin/swaylock -c 000000 && systemctl suspend ;;
        "🔄 Reboot") systemctl reboot ;;
        "⏻ Shutdown") systemctl poweroff ;;
        "🚪 Logout") swaymsg exit ;;
      esac
    '')

    (writeShellScriptBin "gif-picker" ''
      KEY=$(cat ~/.config/gif-picker/giphy-key 2>/dev/null)
      if [[ -z "$KEY" ]]; then
        notify-send "GIF Picker" "No API key found at ~/.config/gif-picker/giphy-key" -u critical
        exit 1
      fi
      query=$(echo "" | wofi --dmenu -p "Search GIFs:")
      [[ -z "$query" ]] && exit 0
      encoded=$(echo -n "$query" | jq -sRr @uri)
      results=$(curl -s "https://api.giphy.com/v1/gifs/search?api_key=$KEY&q=$encoded&limit=20&rating=g")
      urls=$(echo "$results" | jq -r '.data[] | "\(.title) | \(.images.original.url)"')
      [[ -z "$urls" ]] && notify-send "GIF Picker" "No results for: $query" && exit 0
      selected=$(echo "$urls" | wofi -i --dmenu -p "Pick GIF:")
      if [[ -n "$selected" ]]; then
        url=$(echo "$selected" | sed 's/.*| //')
        echo -n "$url" | wl-copy
        notify-send "GIF Picker" "URL copied to clipboard"
      fi
    '')

    (writeShellScriptBin "wofi-sway-keybindings" ''
      CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"
      if [[ ! -f "$CONFIG_FILE" ]]; then
        notify-send "Sway Keybindings" "Config not found: $CONFIG_FILE" -u critical
        exit 1
      fi
      keybindings=$(grep -E '^\s*bindsym' "$CONFIG_FILE" | \
        grep -v '^[[:space:]]*#' | \
        sed 's/^\s*bindsym\s*//' | \
        awk '{
          sub(/\s+#.*$/, "")
          i = 1
          while (i <= NF && $i ~ /^--/) { i++ }
          if (i > NF) next
          keys = $i; i++
          cmd = ""
          for (j = i; j <= NF; j++) { if (j > i) cmd = cmd " "; cmd = cmd $j }
          gsub(/\$mod/, "Mod", keys)
          gsub(/Shift/, "⇧", keys)
          gsub(/Control/, "Ctrl", keys)
          gsub(/\+/, " + ", keys)
          printf "%-35s → %s\n", keys, cmd
        }')
      selected=$(echo "$keybindings" | wofi -i --dmenu -p "Sway Shortcuts" --width=800)
      if [[ -n "$selected" ]]; then
        command=$(echo "$selected" | sed 's/^[^→]*→\s*//')
        [[ -n "$command" ]] && swaymsg "$command"
      fi
    '')

    (writeShellScriptBin "kanshi-menu" ''
      #!/usr/bin/env bash
      profiles=$(grep "profile " ~/.config/kanshi/config 2>/dev/null | awk '{print $2}' | tr -d '{' || echo -e "laptop\nhome")
      selected=$(echo -e "$profiles\nauto" | wofi --dmenu -p 'Display Profile:')

      if [ "$selected" = "auto" ]; then
          systemctl --user restart kanshi
      elif [ -n "$selected" ]; then
          kanshi -p "$selected" &
      fi
    '')

    (writeShellScriptBin "display-manager" ''
      #!/usr/bin/env bash
      KANSHI_CONFIG="$HOME/.config/kanshi/config"
      NWG_PROFILES="$HOME/.config/nwg-displays/profiles"

      # Capture current sway outputs into a kanshi profile
      save_current() {
        local NAME="$1"
        local PROFILE="profile $NAME {"
        while IFS= read -r line; do
          desc=$(echo "$line" | jq -r '"\(.make) \(.model) \(.serial)"' | sed 's/ Unknown$//' | sed 's/ $//')
          x=$(echo "$line" | jq -r '.rect.x')
          y=$(echo "$line" | jq -r '.rect.y')
          w=$(echo "$line" | jq -r '.current_mode.width')
          h=$(echo "$line" | jq -r '.current_mode.height')
          scale=$(echo "$line" | jq -r '.scale')
          transform=$(echo "$line" | jq -r '.transform')
          entry="  output \"$desc\" position $x,$y mode ''${w}x''${h} scale $scale"
          [ "$transform" != "normal" ] && entry="$entry transform $transform"
          PROFILE="$PROFILE
$entry"
        done < <(swaymsg -t get_outputs | jq -c '.[]')
        PROFILE="$PROFILE
}"
        mkdir -p "$(dirname "$KANSHI_CONFIG")"
        # Remove existing profile with same name
        [ -f "$KANSHI_CONFIG" ] && sed -i "/^profile $NAME {/,/^}/d" "$KANSHI_CONFIG"
        # Add header if file is empty/new
        [ ! -s "$KANSHI_CONFIG" ] && echo "# Auto-generated by display-manager" > "$KANSHI_CONFIG"
        echo "" >> "$KANSHI_CONFIG"
        echo "$PROFILE" >> "$KANSHI_CONFIG"
        systemctl --user restart kanshi 2>/dev/null
      }

      # Menu
      profiles=$(ls "$NWG_PROFILES"/*.json 2>/dev/null | xargs -I{} basename {} .json)
      options="📐 Arrange displays\n💾 Save current layout"
      [ -n "$profiles" ] && options="$options\n---\n$(echo "$profiles" | sed 's/^/🖥 /')"

      selected=$(echo -e "$options" | wofi --dmenu -p 'Display Manager')
      [ -z "$selected" ] && exit 0

      case "$selected" in
        "📐 Arrange displays")
          nwg-displays
          NAME=$(echo "" | wofi --dmenu -p 'Save as profile (empty to skip):')
          [ -n "$NAME" ] && save_current "$NAME"
          ;;
        "💾 Save current layout")
          NAME=$(echo "" | wofi --dmenu -p 'Profile name:')
          [ -n "$NAME" ] && save_current "$NAME"
          ;;
        "🖥 "*)
          PROFILE="''${selected#🖥 }"
          nwg-displays
          save_current "$(echo "$PROFILE" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
          ;;
      esac
    '')
    
    (writeShellScriptBin "workspace-rename" ''
      #!/usr/bin/env bash
      # Predefined project workspaces
      projects="mononode\nnativeflow\ncdk\neks-workloads\nlambda\nintegrator\nramp"

      current_num=$(swaymsg -t get_workspaces | jq -r '.[] | select(.focused==true) | .num')
      current_name=$(swaymsg -t get_workspaces | jq -r '.[] | select(.focused==true) | .name')

      selected=$(echo -e "$projects" | wofi --dmenu -p "Rename workspace:")
      [ -z "$selected" ] && exit 0

      swaymsg "rename workspace \"$current_name\" to \"$current_num:$selected\""
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
  };

  # Desktop entry for display manager (shows in wofi drun)
  xdg.desktopEntries.display-manager = {
    name = "Display Manager";
    comment = "Arrange displays and manage profiles";
    exec = "display-manager";
    icon = "preferences-desktop-display";
    categories = [ "Settings" ];
  };

  # Copy swaysome script
  xdg.configFile."sway/swaysome.py" = {
    source = ./swaysome.py;
    executable = true;
  };

  # Copy autotab script
  xdg.configFile."sway/autotab.py" = {
    source = ./autotab.py;
    executable = true;
  };

  # Structured Sway configuration
  xdg.configFile."sway/config".text = ''
    # Sway configuration generated by Home Manager
    set $mod ${swayConfig.config.modifier}
    
    # Display outputs (managed by nwg-displays)
    include ~/.config/sway/outputs
    
    # Prevent workspaces from jumping between displays
    workspace_auto_back_and_forth ${if swayConfig.config.workspaceAutoBackAndForth then "yes" else "no"}
    
    # Set desktop environment
    exec systemctl --user set-environment XDG_CURRENT_DESKTOP=sway
    exec systemctl --user set-environment XDG_SESSION_DESKTOP=sway
    exec systemctl --user import-environment WAYLAND_DISPLAY
    exec systemctl --user set-environment XDG_DATA_DIRS=$HOME/.nix-profile/share:/usr/local/share:/usr/share
    
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

  # Kanshi display profile management (config at ~/.config/kanshi/config)
  services.kanshi.enable = true;

  # Notification daemon
  services.mako = {
    enable = true;
    settings = {
      default-timeout = 5000;
      border-radius = 5;
    };
  };
  
  # Waybar configuration
  programs.waybar = waybarConfig.programs.waybar;
}
