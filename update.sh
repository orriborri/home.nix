#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

# Run from the repo so flake.nix, `nix flake update` and `--flake .` agree.
cd "$(dirname "$0")"

# -u: update flake inputs + dnf upgrade
# --update: only update flake inputs
# --upgrade: only dnf upgrade
# (kiro IDE + CLI now come from nixpkgs and update via `nix flake update`)
# Point nixpkgs-stable at the newest released nixos-YY.MM branch. A branch only
# counts once its YY.MM release tag exists (without -beta/-pre): the branch
# appears at branch-off, as a beta, weeks before the release.
bump_stable_channel() {
    local flake current latest released
    flake=flake.nix
    current=$(grep -oP 'nixpkgs-stable\.url = "github:NixOS/nixpkgs/nixos-\K[0-9]+\.[0-9]+' "$flake") || {
        echo "  ⚠️  nixpkgs-stable not pinned to a nixos-YY.MM branch; skipping"
        return 0
    }
    released=$(git ls-remote --tags https://github.com/NixOS/nixpkgs 'refs/tags/[0-9]*' 2>/dev/null \
        | grep -oP 'refs/tags/\K[0-9]+\.[0-9]+$' | tr '\n' ' ') || true
    latest=$(git ls-remote --heads https://github.com/NixOS/nixpkgs 'refs/heads/nixos-[0-9]*' 2>/dev/null \
        | grep -oP 'refs/heads/nixos-\K[0-9]+\.[0-9]+$' \
        | awk -v now="$(date +%y%m)" -v released=" $released" \
            '{ split($0, v, "."); if (v[1] * 100 + v[2] <= now && index(released, " " $0 " ")) print }' \
        | sort -V | tail -1) || true
    if [[ -z "$latest" ]]; then
        echo "  ⚠️  Could not list nixpkgs branches; keeping nixos-$current"
    elif [[ "$latest" != "$current" ]]; then
        echo "  nixpkgs-stable: nixos-$current → nixos-$latest"
        sed -i "s|nixpkgs-stable\.url = \"github:NixOS/nixpkgs/nixos-$current\"|nixpkgs-stable.url = \"github:NixOS/nixpkgs/nixos-$latest\"|" "$flake"
    else
        echo "  nixpkgs-stable already tracks newest release (nixos-$current)"
    fi
}

if [[ "${1:-}" == "-u" || "${1:-}" == "--update" ]]; then
    echo "🔍 Checking nixpkgs-stable release branch..."
    bump_stable_channel
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "${1:-}" == "-u" || "${1:-}" == "--upgrade" ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

FLATPAK=$(command -v flatpak 2>/dev/null) || true
if [[ -n "$FLATPAK" ]]; then
    echo "📦 Syncing Flatpak packages..."
    MANIFEST=flatpak-packages.txt
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
