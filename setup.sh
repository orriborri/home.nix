#!/bin/bash
# Portable Home Manager Setup Script
# Works on any Linux distribution

set -e

echo "🚀 Setting up Home Manager..."
echo "This script will work on Fedora, Ubuntu, Arch, and other distributions"

# Detect the distribution
if command -v dnf &> /dev/null; then
    DISTRO="fedora"
    PKG_MANAGER="dnf"
    INSTALL_CMD="sudo dnf install -y"
elif command -v apt &> /dev/null; then
    DISTRO="ubuntu"
    PKG_MANAGER="apt"
    INSTALL_CMD="sudo apt install -y"
elif command -v pacman &> /dev/null; then
    DISTRO="arch"
    PKG_MANAGER="pacman"
    INSTALL_CMD="sudo pacman -S --noconfirm"
else
    echo "❌ Unsupported distribution. Please install Nix manually and then run:"
    echo "   git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager"
    echo "   home-manager switch"
    exit 1
fi

echo "📋 Detected distribution: $DISTRO"

# Install system packages
echo "📦 Installing system packages..."
case $DISTRO in
    "fedora")
        $INSTALL_CMD kitty thunar brightnessctl playerctl
        ;;
    "ubuntu")
        # Install desktop utilities for Ubuntu
        sudo apt update
        $INSTALL_CMD kitty thunar brightnessctl playerctl
        ;;
    "arch")
        $INSTALL_CMD kitty thunar brightnessctl playerctl
        ;;
esac

# Install Nix if not present
if ! command -v nix &> /dev/null; then
    echo "📦 Installing Nix package manager..."
    sh <(curl -L https://nixos.org/nix/install) --daemon
    echo ""
    echo "🔄 Nix installed! Please run the following commands to continue:"
    echo "   exec \$SHELL"
    echo "   curl -fsSL https://raw.githubusercontent.com/orriborri/home.nix/main/setup.sh | bash"
    exit 0
fi

# Install Home Manager if not present
if ! command -v home-manager &> /dev/null; then
    echo "🏠 Installing Home Manager..."
    nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
    nix-channel --update
    nix-shell '<home-manager>' -A install
fi

# Clone configuration
echo "📥 Downloading Home Manager configuration..."
if [[ -d ~/.config/home-manager ]]; then
    echo "⚠️  ~/.config/home-manager already exists. Backing up..."
    mv ~/.config/home-manager ~/.config/home-manager.backup.$(date +%s)
fi

git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager

# Apply configuration
echo "⚙️  Applying Home Manager configuration..."
home-manager switch

echo ""
echo "🎉 Setup complete!"
echo ""
echo "📝 Next steps:"
echo "1. Log out of your current session"
echo "2. Log back in to your desktop environment"
echo "3. Enjoy your consistent Home Manager environment!"
echo ""
echo "✨ Your setup is now portable across all machines!"