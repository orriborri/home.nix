{ config, pkgs, lib, powerlineLib ? null, ... }:

{
  programs.waybar = {
    enable = true;
    package = pkgs.waybar;
    systemd.enable = false;
    
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 0;
        width = 0;
        margin = 0;
        spacing = 0;
        mode = "dock";
        reload_style_on_change = true;
        
        modules-left = [
          "group/user"
          "custom/left_div#1"
          "sway/workspaces"
          "custom/right_div#1"
          "sway/window"
        ];
        
        modules-center = [
          "sway/mode"
          "custom/left_div#2"
          "temperature"
          "custom/left_div#3"
          "memory"
          "custom/left_div#4"
          "cpu"
          "custom/left_inv#1"
          "custom/left_div#5"
          "custom/distro"
          "custom/right_div#2"
          "custom/right_inv#1"
          "idle_inhibitor"
          "clock#time"
          "custom/right_div#3"
          "clock#date"
          "custom/right_div#4"
          "network"
          "bluetooth"
          "custom/system_update"
          "custom/right_div#5"
        ];
        
        modules-right = [
          "mpris"
          "custom/left_div#6"
          "group/pulseaudio"
          "custom/left_div#7"
          "backlight"
          "custom/left_div#8"
          "battery"
          "custom/left_inv#2"
          "custom/screenshot"
          "custom/power_menu"
        ];

        # Workspaces
        "sway/workspaces" = {
          disable-scroll-wraparound = true;
          smooth-scrolling-threshold = 4;
          enable-bar-scroll = true;
          format = "{name}";
          persistent-workspaces = {
            "1" = [];
            "2" = [];
            "3" = [];
            "4" = [];
            "5" = [];
          };
        };

        # Window title
        "sway/window" = {
          format = "{title}";
          max-length = 50;
          rewrite = {
            "(.*) — Mozilla Firefox" = "🌎 $1";
            "(.*) - fish" = "> [$1]";
          };
        };

        # Mode indicator
        "sway/mode" = {
          format = "<span style=\"italic\">{}</span>";
        };

        # User group
        "group/user" = {
          orientation = "horizontal";
          modules = [
            "custom/user"
          ];
        };

        "custom/user" = {
          format = "{}";
          exec = "echo $USER";
          interval = "once";
        };

        # System info
        "custom/distro" = {
          format = "{}";
          exec = "uname -r | cut -d'-' -f1";
          interval = 3600;
        };

        # Temperature
        temperature = {
          thermal-zone = 2;
          hwmon-path = "/sys/class/hwmon/hwmon2/temp1_input";
          critical-threshold = 80;
          format-critical = "{temperatureC}°C {icon}";
          format = "{temperatureC}°C {icon}";
          format-icons = ["" "" ""];
        };

        # Memory
        memory = {
          interval = 30;
          format = "{used:0.1f}G/{total:0.1f}G ";
          max-length = 10;
        };

        # CPU
        cpu = {
          interval = 10;
          format = "{usage}% ";
          max-length = 10;
        };

        # Clock
        "clock#time" = {
          format = "{:%H:%M}";
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
        };

        "clock#date" = {
          format = "{:%a %d %b}";
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
        };

        # Network
        network = {
          format-wifi = "{essid} ({signalStrength}%) ";
          format-ethernet = "{ipaddr}/{cidr} ";
          tooltip-format = "{ifname} via {gwaddr} ";
          format-linked = "{ifname} (No IP) ";
          format-disconnected = "Disconnected ⚠";
          format-alt = "{ifname}: {ipaddr}/{cidr}";
        };

        # Bluetooth
        bluetooth = {
          format = " {status}";
          format-disabled = "";
          format-off = "";
          interval = 30;
          on-click = "blueman-manager";
        };

        # System updates
        "custom/system_update" = {
          format = "{}";
          exec = "echo ''";
          interval = 3600;
        };

        # Audio group
        "group/pulseaudio" = {
          orientation = "horizontal";
          modules = [
            "pulseaudio"
            "pulseaudio#microphone"
          ];
        };

        pulseaudio = {
          format = "{volume}% {icon} {format_source}";
          format-bluetooth = "{volume}% {icon} {format_source}";
          format-bluetooth-muted = " {icon} {format_source}";
          format-muted = " {format_source}";
          format-source = "{volume}% ";
          format-source-muted = "";
          format-icons = {
            headphone = "";
            hands-free = "";
            headset = "";
            phone = "";
            portable = "";
            car = "";
            default = ["" "" ""];
          };
          on-click = "pavucontrol";
        };

        "pulseaudio#microphone" = {
          format = "{format_source}";
          format-source = "{volume}% ";
          format-source-muted = "";
          on-click = "pavucontrol";
          on-scroll-up = "pamixer --default-source -i 5";
          on-scroll-down = "pamixer --default-source -d 5";
          scroll-step = 5;
        };

        # Media player
        mpris = {
          format = "{player_icon} {dynamic}";
          format-paused = "{status_icon} <i>{dynamic}</i>";
          player-icons = {
            default = "🎵";
            mpv = "🎵";
          };
          status-icons = {
            paused = "⏸";
          };
        };

        # Backlight
        backlight = {
          device = "intel_backlight";
          format = "{percent}% {icon}";
          format-icons = ["" "" "" "" "" "" "" "" ""];
        };

        # Battery
        battery = {
          states = {
            warning = 30;
            critical = 15;
          };
          format = "{capacity}% {icon}";
          format-charging = "{capacity}% ";
          format-plugged = "{capacity}% ";
          format-alt = "{time} {icon}";
          format-icons = ["" "" "" "" ""];
        };

        # Idle inhibitor
        idle_inhibitor = {
          format = "{icon}";
          format-icons = {
            activated = "";
            deactivated = "";
          };
        };

        # Screenshot
        "custom/screenshot" = {
          format = "📷";
          tooltip = "Screenshot";
          on-click = "screenshot-menu";
        };

        # Power menu
        "custom/power_menu" = {
          format = "⏻";
          tooltip = "Power Menu";
          on-click = "wlogout";
        };

        # Dividers and styling elements
        "custom/left_div#1" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#2" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#3" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#4" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#5" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#6" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#7" = {
          format = "";
          tooltip = false;
        };
        "custom/left_div#8" = {
          format = "";
          tooltip = false;
        };
        "custom/right_div#1" = {
          format = "";
          tooltip = false;
        };
        "custom/right_div#2" = {
          format = "";
          tooltip = false;
        };
        "custom/right_div#3" = {
          format = "";
          tooltip = false;
        };
        "custom/right_div#4" = {
          format = "";
          tooltip = false;
        };
        "custom/right_div#5" = {
          format = "";
          tooltip = false;
        };
        "custom/left_inv#1" = {
          format = "";
          tooltip = false;
        };
        "custom/left_inv#2" = {
          format = "";
          tooltip = false;
        };
        "custom/right_inv#1" = {
          format = "";
          tooltip = false;
        };
      };
    };

    style = ''
      * {
        all: initial;
        font-family: "JetBrainsMono Nerd Font", "JetBrains Mono", monospace;
        font-size: 13px;
      }

      window#waybar {
        background-color: transparent;
        color: #cdd6f4;
        transition-property: background-color;
        transition-duration: 0.5s;
      }

      /* Workspaces */
      #workspaces {
        background: linear-gradient(180deg, #313244, #45475a);
        margin: 5px;
        padding: 0px 1px;
        border-radius: 15px;
        border: 0px;
        font-style: normal;
        opacity: 0.8;
      }

      #workspaces button {
        padding: 0px 5px;
        margin: 4px 3px;
        border-radius: 15px;
        border: 0px;
        color: #cdd6f4;
        background-color: transparent;
        opacity: 0.3;
      }

      #workspaces button.active {
        color: #1e1e2e;
        background: #cba6f7;
        border-radius: 15px;
        min-width: 40px;
        opacity: 1.0;
      }

      #workspaces button:hover {
        color: #1e1e2e;
        background: #cba6f7;
        border-radius: 15px;
        opacity: 0.7;
      }

      /* Window title */
      #window {
        color: #cdd6f4;
        font-weight: normal;
        margin: 5px;
        padding: 0px 15px;
      }

      /* Center modules */
      #temperature,
      #memory,
      #cpu,
      #clock,
      #network,
      #bluetooth {
        background: linear-gradient(180deg, #313244, #45475a);
        color: #cdd6f4;
        margin: 5px 0px;
        padding: 0px 10px;
        border-radius: 15px;
        opacity: 0.8;
      }

      /* Right modules */
      #pulseaudio,
      #backlight,
      #battery {
        background: linear-gradient(180deg, #313244, #45475a);
        color: #cdd6f4;
        margin: 5px 0px;
        padding: 0px 10px;
        border-radius: 15px;
        opacity: 0.8;
      }

      /* Custom modules */
      #custom-screenshot,
      #custom-power_menu {
        background: linear-gradient(180deg, #313244, #45475a);
        color: #cdd6f4;
        margin: 5px;
        padding: 0px 10px;
        border-radius: 15px;
        opacity: 0.8;
      }

      /* Dividers */
      #custom-left_div1,
      #custom-left_div2,
      #custom-left_div3,
      #custom-left_div4,
      #custom-left_div5,
      #custom-left_div6,
      #custom-left_div7,
      #custom-left_div8,
      #custom-right_div1,
      #custom-right_div2,
      #custom-right_div3,
      #custom-right_div4,
      #custom-right_div5 {
        color: #313244;
        font-size: 16px;
      }
    '';
  };
}
