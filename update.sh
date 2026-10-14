#!/usr/bin/env bash
# Simple script to update flake-based Home Manager

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HOST_NAME="$(hostname -s)"
PROFILE=personal
while read -r CONFIGURED_HOST CONFIGURED_PROFILE; do
  if [[ "$CONFIGURED_HOST" == "$HOST_NAME" ]]; then
    PROFILE="$CONFIGURED_PROFILE"
    break
  fi
done < "$SCRIPT_DIR/config/host-profiles"
PROFILE="${HOME_MANAGER_PROFILE:-$PROFILE}"
UPDATE_INPUTS=false
UPGRADE_SYSTEM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      if [[ $# -lt 2 ]]; then
        echo "--profile requires personal or work" >&2
        exit 1
      fi
      PROFILE="$2"
      shift 2
      ;;
    -u)
      UPDATE_INPUTS=true
      UPGRADE_SYSTEM=true
      shift
      ;;
    --update)
      UPDATE_INPUTS=true
      shift
      ;;
    --upgrade)
      UPGRADE_SYSTEM=true
      shift
      ;;
    *)
      echo "Usage: $0 [--profile personal|work] [-u|--update|--upgrade]" >&2
      exit 1
      ;;
  esac
done

case "$PROFILE" in
  personal) CONFIGURATION=orre-personal ;;
  work) CONFIGURATION=orre-work ;;
  *)
    echo "Unknown profile: $PROFILE (expected personal or work)" >&2
    exit 1
    ;;
esac

# -u: update flake inputs + dnf upgrade
# --update: only update flake inputs
# --upgrade: only dnf upgrade
# (kiro IDE + CLI now come from nixpkgs and update via `nix flake update`)
if [[ "$UPDATE_INPUTS" == true ]]; then
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "$UPGRADE_SYSTEM" == true ]]; then
    echo "⬆️  Upgrading system packages..."
    sudo dnf upgrade --allowerasing -y
fi

FLATPAK=$(command -v flatpak 2>/dev/null || true)
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

echo "🏠 Switching to $PROFILE configuration for $HOST_NAME..."
if command -v home-manager >/dev/null 2>&1; then
  home-manager switch -b backup --flake ".#$CONFIGURATION"
else
  nix run --inputs-from . home-manager -- switch -b backup --flake ".#$CONFIGURATION"
fi

echo "🧹 Garbage collecting old generations (>7d) and optimising Nix store..."
nix-collect-garbage --delete-older-than 7d
nix store optimise --verbose

echo "✅ Update complete!"
