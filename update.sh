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

FLATPAK=$(command -v flatpak 2>/dev/null)
if [[ -n "$FLATPAK" ]]; then
    echo "📦 Syncing Flatpak packages..."
    MANIFEST="$(dirname "$0")/flatpak-packages.txt"
    if [[ -f "$MANIFEST" ]]; then
        # Ensure flathub remote exists
        $FLATPAK remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        # Install any missing packages from the manifest
        while IFS= read -r app; do
            app="${app%%#*}"       # strip comments
            app="${app// /}"       # strip whitespace
            [[ -z "$app" ]] && continue
            if ! $FLATPAK info --user "$app" &>/dev/null && \
               ! $FLATPAK info "$app" &>/dev/null; then
                echo "  Installing $app..."
                $FLATPAK install --user -y flathub "$app"
            fi
        done < "$MANIFEST"
    fi

    # Update all installed flatpaks
    echo "  Updating installed flatpaks..."
    $FLATPAK update -y || true
fi

echo "🏠 Switching to configuration..."
home-manager switch -b backup --flake .#orre

echo "🧹 Garbage collecting old generations (>7d) and optimising Nix store..."
nix-collect-garbage --delete-older-than 7d
nix store optimise --verbose

echo "✅ Update complete!"
