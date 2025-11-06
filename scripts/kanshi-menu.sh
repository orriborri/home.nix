#!/usr/bin/env bash

# Get available profiles or use fallback
profiles=$(ls ~/.config/kanshi/*.conf 2>/dev/null | xargs -n1 basename | sed 's/\.conf$//' || echo -e "laptop\nhome\nsamsung-monitor\ntriple")
echo profiles: "$profiles" 
# Add auto option and show menu
selected=$(echo -e "$profiles\nauto" | wofi --dmenu --prompt='Display Profile:')

# Handle selection
if [ "$selected" = "auto" ]; then
    systemctl --user restart kanshi
elif [ -n "$selected" ]; then
    ~/.config/kanshi/switch-profile.sh "$selected"
fi