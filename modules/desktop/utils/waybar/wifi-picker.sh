#!/usr/bin/env bash
# WiFi picker for Waybar using wofi and nmcli

# Rescan networks
nmcli dev wifi rescan 2>/dev/null

# List networks: SSID, signal strength, security
network=$(nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list | \
  awk -F: 'NF>=2 && $1!="" { if (!seen[$1]++) printf "%-30s %3s%% %s\n", $1, $2, $3 }' | \
  sort -t'%' -k1 -rn | \
  wofi --dmenu --prompt='WiFi Network:' --width=400 --height=300)

[ -z "$network" ] && exit 0

ssid=$(echo "$network" | sed 's/\s*[0-9]*%.*$//' | xargs)

# Try connecting (works for known networks)
if ! nmcli dev wifi connect "$ssid" 2>/dev/null; then
  # Prompt for password
  pass=$(wofi --dmenu --prompt="Password for $ssid:" --password --width=400 --height=100)
  [ -z "$pass" ] && exit 0
  nmcli dev wifi connect "$ssid" password "$pass"
fi
