#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# -u: update flake inputs + dnf upgrade
# --update: only update flake inputs
# --upgrade: only dnf upgrade
# (kiro IDE + CLI now come from nixpkgs and update via `nix flake update`)
if [[ "${1:-}" == "-u" || "${1:-}" == "--update" ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "${1:-}" == "-u" || "${1:-}" == "--upgrade" ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

if command -v flatpak &>/dev/null; then
    echo "📦 Updating Flatpak packages..."
    flatpak update -y
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre

echo "🧹 Garbage collecting old generations (>7d) and optimising Nix store..."
nix-collect-garbage --delete-older-than 7d
nix store optimise --verbose

echo "✅ Update complete!"
