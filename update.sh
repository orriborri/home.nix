#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# -u: update flake inputs + dnf upgrade + kiro
# --update: only update flake inputs
# --upgrade: only dnf upgrade
# --kiro: only update kiro
# --gnome-save: save current GNOME dconf settings to nix
if [[ "${1:-}" == "-u" || "${1:-}" == "--update" ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "${1:-}" == "-u" || "${1:-}" == "--upgrade" ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

if [[ "${1:-}" == "-u" || "${1:-}" == "--kiro" ]]; then
    echo "🤖 Checking for Kiro IDE updates..."
    KIRO_META=$(curl -sL "https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json")
    LATEST_VERSION=$(echo "$KIRO_META" | jq -r '.releases[-1].version')
    CURRENT_VERSION=$(grep 'version = ' packages/kiro.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')

    if [[ "$LATEST_VERSION" != "$CURRENT_VERSION" && -n "$LATEST_VERSION" && "$LATEST_VERSION" != "null" ]]; then
        echo "  Updating Kiro: $CURRENT_VERSION → $LATEST_VERSION"
        KIRO_URL="https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${LATEST_VERSION}/tar/kiro-ide-${LATEST_VERSION}-stable-linux-x64.tar.gz"
        NEW_HASH=$(nix-prefetch-url --unpack "$KIRO_URL" 2>/dev/null | tail -1)
        NEW_SRI=$(nix hash convert --hash-algo sha256 --to sri "$NEW_HASH")

        sed -i "s|version = \"$CURRENT_VERSION\"|version = \"$LATEST_VERSION\"|g" packages/kiro.nix packages/kiro-package.nix
        sed -i "s|sha256 = \".*\"|sha256 = \"$NEW_SRI\"|" packages/kiro.nix
        echo "  ✅ Kiro updated to $LATEST_VERSION"
    else
        echo "  Kiro is already at latest ($CURRENT_VERSION)"
    fi
fi

if command -v flatpak &>/dev/null; then
    echo "📦 Updating Flatpak packages..."
    flatpak update -y
fi

if [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]; then
    # Check for dconf drift only on paths we manage
    MANAGED_PATHS=(
      /org/gnome/desktop/interface/
      /org/gnome/desktop/input-sources/
      /org/gnome/desktop/wm/keybindings/
      /org/gnome/desktop/wm/preferences/
      /org/gnome/mutter/
      /org/gnome/mutter/keybindings/
      /org/gnome/shell/keybindings/
      /org/gnome/shell/app-switcher/
      /org/gnome/shell/enabled-extensions
      /org/gnome/settings-daemon/plugins/color/
      /org/gnome/settings-daemon/plugins/media-keys/
    )

    LIVE_DUMP=$(mktemp)
    NIX_DUMP=$(mktemp)
    for path in "${MANAGED_PATHS[@]}"; do
      dconf dump "$path" >> "$LIVE_DUMP" 2>/dev/null
    done

    STORED_DUMP="$(dirname "$0")/modules/desktop/gnome-dconf.dump"
    if [ -f "$STORED_DUMP" ]; then
      for path in "${MANAGED_PATHS[@]}"; do
        grep -A 100 "^\[${path#/}" "$STORED_DUMP" 2>/dev/null >> "$NIX_DUMP" || true
      done
    fi

    if [ -f "$STORED_DUMP" ] && ! diff -q "$LIVE_DUMP" "$NIX_DUMP" &>/dev/null; then
        echo "⚠️  GNOME dconf has drifted from nix config."
        echo "  [s] Save live settings → nix (overwrite nix with current GNOME)"
        echo "  [r] Restore nix → GNOME (discard live changes, apply nix)"
        echo "  [d] Show diff"
        echo "  [n] Skip"
        read -rp "  Choice [s/r/d/n]: " choice
        case "$choice" in
            s)
                echo "🖥️  Saving GNOME dconf settings to nix..."
                "$(dirname "$0")/scripts/sync-gnome-settings.sh"
                ;;
            r)
                echo "🔄 Restoring nix settings to GNOME (will apply on switch)..."
                ;;
            d)
                diff --color=auto "$NIX_DUMP" "$LIVE_DUMP" | head -50
                read -rp "  Save live → nix? [y/N]: " save
                [[ "$save" == "y" ]] && "$(dirname "$0")/scripts/sync-gnome-settings.sh"
                ;;
            *) echo "  Skipping." ;;
        esac
    fi
    rm -f "$LIVE_DUMP" "$NIX_DUMP"
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre

# Update stored dconf dump after successful switch
if [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]; then
    dconf dump / > "$(dirname "$0")/modules/desktop/gnome/dconf.dump"
fi
pkill waybar
swaymsg reload
kanshi status &

echo "🧹 Garbage collecting old generations (>7d) and optimising Nix store..."
nix-collect-garbage --delete-older-than 7d
nix store optimise --verbose

echo "✅ Update complete!"
