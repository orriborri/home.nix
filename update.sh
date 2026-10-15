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
# Point nixpkgs-stable at the newest released nixos-YY.MM branch. A branch only
# counts once its YY.MM release tag exists (without -beta/-pre): the branch
# appears at branch-off, as a beta, weeks before the release.
bump_stable_channel() {
    local flake current latest released
    flake=flake.nix
    current=$(grep -m1 -oP 'nixpkgs-stable\.url = "github:NixOS/nixpkgs/nixos-\K[0-9]+\.[0-9]+' "$flake") || {
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

if [[ "$UPDATE_INPUTS" == true ]]; then
    echo "🔍 Checking nixpkgs-stable release branch..."
    bump_stable_channel
    echo "🔄 Updating flake inputs..."
    nix flake update
fi

if [[ "$UPGRADE_SYSTEM" == true ]]; then
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

        # Ask about installed apps the manifest does not list: yes adds the
        # app to the manifest, no uninstalls it. Only asks on a terminal.
        if [[ -t 0 ]]; then
            mapfile -t wanted < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$MANIFEST")
            mapfile -t installed < <($FLATPAK list --app --columns=application,installation)
            mapfile -t ids < <(printf '%s\n' "${installed[@]}" | cut -f1 | sort -u)
            for app in "${ids[@]}"; do
                [[ -z "$app" ]] && continue
                [[ " ${wanted[*]} " == *" $app "* ]] && continue
                read -r -p "  $app is not in $MANIFEST. Add it? [Y/n, n uninstalls] " answer || true
                if [[ "$answer" == [Nn]* ]]; then
                    for row in "${installed[@]}"; do
                        [[ "${row%%$'\t'*}" == "$app" ]] || continue
                        $FLATPAK uninstall -y --"${row#*$'\t'}" "$app"
                    done
                else
                    grep -qx '# Added by update.sh' "$MANIFEST" || printf '\n# Added by update.sh\n' >> "$MANIFEST"
                    echo "$app" >> "$MANIFEST"
                fi
            done
        else
            echo "  ⚠️  No terminal; not asking about apps missing from $MANIFEST"
        fi
    fi

    # Remove runtimes no installed app uses any more
    $FLATPAK uninstall --unused -y || true

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
