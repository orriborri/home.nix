

{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [ 
    waylogout
  ];
  

  # Wlogout configuration for logout menu
  xdg.configFile."wlogout/layout".text = ''
    {
        "label" : "lock",
        "action" : "hyprlock",
        "text" : "Lock",
        "keybind" : "l"
    }
    {
        "label" : "hibernate",
        "action" : "systemctl hibernate",
        "text" : "Hibernate",
        "keybind" : "h"
    }
    {
        "label" : "logout",
        "action" : "hyprctl dispatch exit 0",
        "text" : "Logout",
        "keybind" : "e"
    }
    {
        "label" : "shutdown",
        "action" : "systemctl poweroff",
        "text" : "Shutdown",
        "keybind" : "s"
    }
    {
        "label" : "suspend",
        "action" : "systemctl suspend",
        "text" : "Suspend",
        "keybind" : "u"
    }
    {
        "label" : "reboot",
        "action" : "systemctl reboot",
        "text" : "Reboot",
        "keybind" : "r"
    }
  '';
  
  # Basic wlogout styling
  xdg.configFile."wlogout/style.css".text = ''
    * {
        background-image: none;
        box-shadow: none;
    }
    
    window {
        background-color: rgba(12, 12, 12, 0.9);
    }
    
    button {
        color: #FFFFFF;
        background-color: #1E1E1E;
        border-style: solid;
        border-width: 2px;
        border-radius: 20px;
        border-color: #33ccff;
        background-repeat: no-repeat;
        background-position: center;
        background-size: 25%;
        margin: 5px;
        transition: all 0.3s ease-in-out;
    }
    
    button:focus, button:active, button:hover {
        background-color: #33ccff;
        outline-style: none;
    }
  '';
  
  # Restart Waybar when configuration changes
  home.activation.restartWaybar = lib.hm.dag.entryAfter ["writeBoundary"] ''
    if [[ -v HYPRLAND_INSTANCE_SIGNATURE ]] && command -v waybar >/dev/null 2>&1; then
      echo "🔄 Restarting Waybar..."
      $DRY_RUN_CMD pkill waybar || true
      if [[ ! -v DRY_RUN ]]; then
        # Wait a moment for waybar to fully stop
        sleep 0.5
        # Start waybar in background
        waybar &
        echo "✅ Waybar restarted"
      else
        echo "📋 Would restart Waybar"
      fi
    else
      echo "ℹ️  Not in Hyprland session or waybar not available, skipping restart"
    fi
  '';
}
