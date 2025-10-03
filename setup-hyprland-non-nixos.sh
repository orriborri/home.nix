#!/bin/bash
# Hyprland Setup Script for Non-NixOS Systems
# This script sets up Hyprland with Home Manager on any Linux distribution

set -e

echo "🚀 Setting up Hyprland with Home Manager..."

# Detect the distribution
if command -v dnf &> /dev/null; then
    DISTRO="fedora"
    PKG_MANAGER="dnf"
elif command -v apt &> /dev/null; then
    DISTRO="ubuntu"
    PKG_MANAGER="apt"
elif command -v pacman &> /dev/null; then
    DISTRO="arch"
    PKG_MANAGER="pacman"
else
    echo "❌ Unsupported distribution. Please install Hyprland manually."
    exit 1
fi

echo "📋 Detected distribution: $DISTRO"

# Install Hyprland system packages
echo "📦 Installing Hyprland system packages..."
case $DISTRO in
    "fedora")
        sudo dnf install -y hyprland hyprutils hyprlang hyprcursor xdg-desktop-portal-hyprland kitty waybar wofi
        ;;
    "ubuntu")
        # Add necessary repositories for Ubuntu
        sudo add-apt-repository ppa:hyprland/hyprland -y
        sudo apt update
        sudo apt install -y hyprland kitty waybar wofi
        ;;
    "arch")
        sudo pacman -S hyprland kitty waybar wofi xdg-desktop-portal-hyprland
        ;;
esac

# Create desktop session file
echo "🖥️  Creating desktop session file..."
sudo mkdir -p /usr/share/wayland-sessions
sudo tee /usr/share/wayland-sessions/hyprland.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland compositor
Exec=Hyprland
Type=Application
EOF

# Install Nix if not present
if ! command -v nix &> /dev/null; then
    echo "📦 Installing Nix..."
    sh <(curl -L https://nixos.org/nix/install) --daemon
    echo "🔄 Please restart your shell and run this script again to continue with Home Manager setup."
    exit 0
fi

# Install Home Manager if not present
if ! command -v home-manager &> /dev/null; then
    echo "🏠 Installing Home Manager..."
    nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
    nix-channel --update
    nix-shell '<home-manager>' -A install
fi

echo "✅ Hyprland system setup complete!"
echo ""
echo "📝 Next steps:"
echo "1. Copy your Home Manager configuration to ~/.config/home-manager/"
echo "2. Run 'home-manager switch'"
echo "3. Log out and select 'Hyprland' from the login screen"
echo ""
echo "🎉 Enjoy your Hyprland setup!"