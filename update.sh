#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

echo "🔄 Updating flake inputs..."
nix flake update

echo "🏠 Switching to updated configuration..."
home-manager switch --flake .#orre

echo "✅ Update complete!"