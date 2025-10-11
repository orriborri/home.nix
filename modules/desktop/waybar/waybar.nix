{ config, pkgs, lib, powerlineLib ? null, ... }:

let
  # Define powerline modules and colors
  rightModules = [ "custom/kanshi" "custom/power-profile" "custom/audio" "network" "memory" "cpu" "custom/temperature" "battery" "sway/language" "tray" "clock#date" "clock#time" ];
  rightColors = [ "rgba(40, 40, 40, 0.8784313725)" "@power" "@sound" "@network" "@memory" "@cpu" "@temp" "@battery" "@layout" "@date" "@date" "@time" ];
  
  rightPowerline = if powerlineLib != null then powerlineLib.mkPowerline rightModules rightColors else {
    arrows = {};
    moduleOrder = rightModules;
    arrowCSS = "";
  };
in
{
  programs.waybar = {
    enable = true;
    package = pkgs.waybar;
    systemd.enable = false;
    
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        modules-left = [ "sway/mode" "sway/workspaces" "custom/arrow14" "sway/window" ];
        modules-right = rightPowerline.moduleOrder;
        
        battery = {
          interval = 10;
          states = {
            warning = 30;
            critical = 15;
          };
          format-time = "{H}:{M:02}";
          format = "{icon} {capacity}% ({time})";
          format-charging = " {capacity}% ({time})";
          format-charging-full = " {capacity}%";
          format-full = "{icon} {capacity}%";
          format-alt = "{icon} {power}W";
          format-icons = [ "" "" "" "" "" ];
          tooltip = false;
        };
        
        "clock#time" = {
          interval = 10;
          format = "{:%H:%M}";
          tooltip = false;
        };
        
        "clock#date" = {
          interval = 20;
          format = "{:%e %b %Y}";
          tooltip = false;
        };
        
        cpu = {
          interval = 5;
          tooltip = false;
          format = " {usage}%";
          format-alt = " {load}";
          states = {
            warning = 70;
            critical = 90;
          };
        };
        
        "sway/language" = {
          format = " {}";
          min-length = 5;
          tooltip = false;
        };
        
        memory = {
          interval = 5;
          format = " {used:0.1f}G/{total:0.1f}G";
          states = {
            warning = 70;
            critical = 90;
          };
          tooltip = false;
        };
        
        network = {
          interval = 5;
          format-wifi = " {essid} ({signalStrength}%)";
          format-ethernet = " {ifname}";
          format-disconnected = "No connection";
          format-alt = " {ipaddr}/{cidr}";
          tooltip = false;
        };
        
        "sway/workspaces" = {
          disable-scroll-wraparound = true;
          smooth-scrolling-threshold = 4;
          enable-bar-scroll = true;
          format = "{name}";
        };
        
        "custom/audio" = {
          exec = "sink_vol=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -o '[0-9]*%' | head -1); source_vol=$(pactl get-source-volume @DEFAULT_SOURCE@ | grep -o '[0-9]*%' | head -1); echo \"🎧 $sink_vol 🎤 $source_vol\"";
          interval = 2;
          format = "{}";
          tooltip-format = "Left: Output | Right: Input | Middle: Mute mic";
          on-click = "pactl list sinks short | cut -f2 | wofi --dmenu --prompt='Output Device:' | xargs -I {} pactl set-default-sink {}";
          on-click-right = "pactl list sources short | grep -v monitor | cut -f2 | wofi --dmenu --prompt='Input Device:' | xargs -I {} pactl set-default-source {}";
          on-click-middle = "pactl set-source-mute @DEFAULT_SOURCE@ toggle";
          scroll-step = 5;
          on-scroll-up = "pactl set-sink-volume @DEFAULT_SINK@ +5%";
          on-scroll-down = "pactl set-sink-volume @DEFAULT_SINK@ -5%";
          tooltip = true;
        };
        
        "custom/temperature" = {
          exec = "temp=$(cat /sys/class/thermal/thermal_zone*/temp | head -1); temp_c=$((temp/1000)); echo \"🌡️ \${temp_c}°C\"";
          interval = 5;
          format = "{}";
          exec-if = "test -f /sys/class/thermal/thermal_zone0/temp";
          tooltip = false;
        };
        
        "custom/kanshi" = {
          exec = "echo '🖥️'";
          format = "{}";
          tooltip-format = "Display Profile Manager - Click for menu";
          on-click = "echo -e \"laptop\\nhome\\nsamsung-monitor\\ntriple\\nauto\" | wofi --dmenu --prompt='Display Profile:' | while read profile; do if [ \"$profile\" = \"auto\" ]; then systemctl --user restart kanshi; else ~/.config/kanshi/switch-profile.sh \"$profile\"; fi; done";
          on-click-right = "systemctl --user restart kanshi";
          tooltip = true;
        };
        
        tray.icon-size = 18;
        
        "custom/arrow1" = {
           format = "";
          tooltip = false;
        };
        "custom/arrow2" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow3" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow4" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow5" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow6" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow7" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow8" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow9" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow10" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow11" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow12" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow13" = {
          format = "";
          tooltip = false;
        };
        "custom/arrow14" = {
          format = "";
          tooltip = false;
        };
        
        "custom/power-profile" = {
          exec = "profile=$(/home/orre/.nix-profile/bin/powerprofilesctl get); case $profile in performance) echo '🔧 🐅';; power-saver) echo '🔧 🐢';; *) echo '🔧 🐶';; esac";
          interval = 5;
          format = "{}";
          on-click = "current=$(/home/orre/.nix-profile/bin/powerprofilesctl get); case $current in performance) /home/orre/.nix-profile/bin/powerprofilesctl set balanced;; balanced) /home/orre/.nix-profile/bin/powerprofilesctl set power-saver;; power-saver) /home/orre/.nix-profile/bin/powerprofilesctl set performance;; esac";
          tooltip-format = "Click to cycle power profile";
        };
      } // rightPowerline.arrows // {
      };
      
      secondaryBar = {
        output = "HDMI-A-1";
        layer = "top";
        position = "top";
        modules-left = [ "sway/workspaces" ];
        modules-right = [ "clock#time" ];
        
        "clock#time" = {
          interval = 10;
          format = "{:%H:%M}";
          tooltip = false;
        };
        
        "sway/workspaces" = {
          disable-scroll-wraparound = true;
          smooth-scrolling-threshold = 4;
          enable-bar-scroll = true;
          format = "{name}";
        };
      };
    };
    
    style = ''
      /* Keyframes */
      @keyframes blink-critical {
      	to {
      		background-color: @critical;
      	}
      }

      /* Colors (gruvbox) */
      @define-color black	#282828;
      @define-color red	#cc241d;
      @define-color green	#98971a;
      @define-color yellow	#d79921;
      @define-color blue	#458588;
      @define-color purple	#b16286;
      @define-color aqua	#689d6a;
      @define-color gray	#a89984;
      @define-color brgray	#928374;
      @define-color brred	#fb4934;
      @define-color brgreen	#b8bb26;
      @define-color bryellow	#fabd2f;
      @define-color brblue	#83a598;
      @define-color brpurple	#d3869b;
      @define-color braqua	#8ec07c;
      @define-color white	#ebdbb2;
      @define-color bg2	#504945;

      @define-color warning 	@bryellow;
      @define-color critical	@red;
      @define-color mode	@black;
      @define-color unfocused	@bg2;
      @define-color focused	@braqua;
      @define-color inactive	@purple;
      @define-color sound	@brpurple;
      @define-color network	@purple;
      @define-color memory	@braqua;
      @define-color cpu	@green;
      @define-color temp	@brgreen;
      @define-color layout	@bryellow;
      @define-color battery	@aqua;
      @define-color date	@black;
      @define-color time	@white;
      @define-color music	@brblue;
      @define-color power	@bryellow;

      /* Reset all styles */
      * {
      	border: none;
      	border-radius: 0;
      	min-height: 0;
      	margin: 0;
      	padding: 0;
      	box-shadow: none;
      	text-shadow: none;
      	-gtk-icon-shadow: none;
      }

      /* The whole bar */
      #waybar {
      	background: rgba(40, 40, 40, 0.8784313725);
      	color: @white;
      	font-family: "JetBrainsMono Nerd Font", "JetBrains Mono", monospace;
      	font-size: 10pt;
      }

      /* Each module */
      #clock,
      #cpu,
      #language,
      #memory,
      #mode,
      #network,
      #pulseaudio,
      #temperature,
      #tray,
      #backlight,
      #idle_inhibitor,
      #disk,
      #user,
      #mpris {
      	padding-left: 20pt;
      	padding-right: 20pt;
      }

      /* Each critical module */
      #mode,
      #memory.critical,
      #cpu.critical,
      #temperature.critical,
      #battery.critical.discharging {
      	animation-timing-function: linear;
      	animation-iteration-count: infinite;
      	animation-direction: alternate;
      	animation-name: blink-critical;
      	animation-duration: 1s;
      }

      /* Each warning */
      #network.disconnected,
      #memory.warning,
      #cpu.warning,
      #temperature.warning,
      #battery.warning.discharging {
      	color: @warning;
      }

      /* Workspaces stuff */
      #workspaces button {
      	padding-left: 2pt;
      	padding-right: 2pt;
      	color: @white;
      	background: @unfocused;
      }

      /* Inactive (on unfocused output) */
      #workspaces button.visible {
      	color: @white;
      	background: @inactive;
      }

      /* Active (on focused output) */
      #workspaces button.focused {
      	color: @black;
      	background: @focused;
      }

      /* Contains an urgent window */
      #workspaces button.urgent {
      	color: @black;
      	background: @warning;
      }

      /* Style when cursor is on the button */
      #workspaces button:hover {
      	background: @black;
      	color: @white;
      }

      #window {
      	margin-right: 35pt;
      	margin-left: 35pt;
      }

      #pulseaudio {
      	background: @sound;
      	color: @black;
      }

      #network {
      	background: @network;
      	color: @white;
      }

      #mpris {
      	background: @music;
      	color: @black;
      }

      #memory {
      	background: @memory;
      	color: @black;
      }

      #cpu {
      	background: @cpu;
      	color: @white;
      }

      #temperature {
      	background: @temp;
      	color: @black;
      }

      #language {
      	background: @layout;
      	color: @black;
      }

      #battery {
      	background: @battery;
      	color: @white;
      }

      #tray {
      	background: @date;
      }

      #clock.date {
      	background: @date;
      	color: @white;
      }

      #clock.time {
      	background: @time;
      	color: @black;
      }

      #custom-arrow1 {
      	font-size: 11pt;
      	color: @time;
      	background: @date;
      }

      #custom-arrow2 {
      	font-size: 11pt;
      	color: @time;
      	background: @date;
      }

      #custom-arrow3 {
      	font-size: 11pt;
      	color: @date;
      	background: @layout;
      }

      #custom-arrow4 {
      	font-size: 11pt;
      	color: @layout;
      	background: @battery;
      }

      #custom-arrow5 {
      	font-size: 11pt;
      	color: @battery;
      	background: @temp;
      }

      #custom-arrow6 {
      	font-size: 11pt;
      	color: @temp;
      	background: @cpu;
      }

      #custom-arrow7 {
      	font-size: 11pt;
      	color: @cpu;
      	background: @memory;
      }

      #custom-arrow8 {
      	font-size: 11pt;
      	color: @memory;
      	background: @network;
      }

      #custom-arrow9 {
      	font-size: 11pt;
      	color: @network;
      	background: @sound;
      }

      #custom-arrow10 {
      	font-size: 11pt;
      	color: @sound;
      	background: @power;
      }

      #custom-arrow11 {
      	font-size: 11pt;
      	color: rgba(40, 40, 40, 0.8784313725);
      	background: @power;
      }
      
      #custom-audio {
      	background: @sound;
      	color: @black;
      }
      
      #custom-temperature {
      	background: @temp;
      	color: @black;
      }
      
      #custom-power-profile {
      	background: @power;
      	color: @black;
      }
      
      #custom-kanshi {
      	background: rgba(40, 40, 40, 0.8784313725);
      	color: @white;
      }
      
      #custom-arrow12 {
      	font-size: 11pt;
      	color: transparent;
      	background: rgba(40, 40, 40, 0.8784313725);
      }
      
      #custom-arrow13 {
      	font-size: 11pt;
      	color: rgba(40, 40, 40, 0.8784313725);
      	background: rgba(40, 40, 40, 0.8784313725);
      }
      
      #custom-arrow14 {
      	font-size: 11pt;
      	color: @unfocused;
      	background: transparent;
      }
      
      ${rightPowerline.arrowCSS}
    '';
  };
}