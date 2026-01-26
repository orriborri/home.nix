#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# Only update flake inputs if --update flag is passed
if [[ "$1" == "--update" ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre
pkill waybar
swaymsg reload
kanshi status &
echo "✅ Update complete!"
