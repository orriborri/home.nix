#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# -u: update flake inputs + dnf upgrade + kiro
# --update: only update flake inputs
# --upgrade: only dnf upgrade
# --kiro: only update kiro
if [[ "$1" == "-u" || "$1" == "--update" ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "$1" == "-u" || "$1" == "--upgrade" ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

if [[ "$1" == "-u" || "$1" == "--kiro" ]]; then
    echo "🤖 Checking for Kiro IDE updates..."
    KIRO_META=$(curl -sL "https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json")
    LATEST_VERSION=$(echo "$KIRO_META" | jq -r '.releases[-1].version')
    CURRENT_VERSION=$(grep 'version = ' packages/kiro.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')

    if [[ "$LATEST_VERSION" != "$CURRENT_VERSION" && -n "$LATEST_VERSION" && "$LATEST_VERSION" != "null" ]]; then
        echo "  Updating Kiro: $CURRENT_VERSION → $LATEST_VERSION"
        KIRO_URL="https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${LATEST_VERSION}/tar/kiro-ide-${LATEST_VERSION}-stable-linux-x64.tar.gz"
        NEW_HASH=$(nix-prefetch-url --unpack "$KIRO_URL" 2>/dev/null | tail -1)
        NEW_SRI=$(nix hash to-sri --type sha256 "$NEW_HASH")

        sed -i "s|version = \"$CURRENT_VERSION\"|version = \"$LATEST_VERSION\"|g" packages/kiro.nix packages/kiro-package.nix
        sed -i "s|sha256 = \".*\"|sha256 = \"$NEW_SRI\"|" packages/kiro.nix
        echo "  ✅ Kiro updated to $LATEST_VERSION"
    else
        echo "  Kiro is already at latest ($CURRENT_VERSION)"
    fi
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre
pkill waybar
swaymsg reload
kanshi status &

echo "🧹 Garbage collecting and optimising Nix store..."
nix store gc --verbose
nix store optimise --verbose

echo "✅ Update complete!"
