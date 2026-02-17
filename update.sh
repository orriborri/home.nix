#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# -u: update flake inputs + dnf upgrade
# --update: only update flake inputs
# --upgrade: only dnf upgrade
if [[ "$1" == "-u" || "$1" == "--update" ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "$1" == "-u" || "$1" == "--upgrade" ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre
pkill waybar
swaymsg reload
kanshi status &
echo "✅ Update complete!"
