# Portable Hyprland Setup with Home Manager

This configuration automatically adapts to work on both NixOS and non-NixOS systems.

## 🚀 Quick Setup on Any New System

### Step 1: One-Line Install Script

```bash
# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/orriborri/home.nix/main/setup.sh | bash
```

OR manually:

### Step 1: Install Prerequisites

**On Fedora/CentOS/RHEL:**
```bash
# Install system Hyprland (recommended for better hardware support)
sudo dnf install hyprland kitty waybar wofi thunar

# Install Nix package manager
sh <(curl -L https://nixos.org/nix/install) --daemon
```

**On Ubuntu/Debian:**
```bash
# Install Hyprland
sudo add-apt-repository ppa:hyprland/hyprland -y
sudo apt update && sudo apt install hyprland kitty waybar wofi thunar

# Install Nix package manager  
sh <(curl -L https://nixos.org/nix/install) --daemon
```

**On Arch/Manjaro:**
```bash
# Install system packages
sudo pacman -S hyprland kitty waybar wofi thunar

# Install Nix package manager
sh <(curl -L https://nixos.org/nix/install) --daemon
```

**On NixOS:**
```nix
# Add to /etc/nixos/configuration.nix
programs.hyprland.enable = true;
services.xserver.displayManager.gdm = {
  enable = true;
  wayland = true;
};
```

### Step 2: Install Home Manager

```bash
# Restart shell first to load Nix
exec $SHELL

# Install Home Manager
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
nix-shell '<home-manager>' -A install
```

### Step 3: Deploy Configuration

```bash
# Clone your home-manager config
git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager

# Apply configuration
home-manager switch
```

### Step 4: Profit! 🎉

The configuration will automatically:
- ✅ Detect your system type (NixOS vs non-NixOS)
- ✅ Install necessary packages through Nix
- ✅ Force-apply your custom Hyprland configuration
- ✅ Create desktop session files
- ✅ Set up proper environment variables
- ✅ Create a restore script if the config gets overwritten

## 🔧 **Smart Features**

### 🛡️ **Config Protection**
- Automatically overwrites any auto-generated configs
- Creates a restore script at `~/.config/hypr/restore-config.sh`
- Run the restore script if your config gets overwritten

### 📦 **Cross-Platform Packages**
- Kitty terminal (managed by Home Manager)
- Waybar status bar
- Wofi application launcher
- Thunar file manager
- Wayland utilities
- Firefox with Wayland support

### ⚙️ **Adaptive Configuration**
- Same config works on any Linux distribution
- Uses system Hyprland when available (better GPU support)
- Falls back to Nix Hyprland as backup
- Optimized for your hardware

## 🚀 **Using on New Machines**

1. **Fresh machine**: Run the one-line installer
2. **Existing machine**: Just clone config and run `home-manager switch`
3. **Config gets overwritten**: Run `~/.config/hypr/restore-config.sh`
4. **Log out and select "Hyprland" from login screen**

## 🔄 **Updating**

```bash
# Update configuration
cd ~/.config/home-manager
git pull
home-manager switch

# If config gets overwritten, restore it:
~/.config/hypr/restore-config.sh
```

## 🛠️ **Troubleshooting**

### Config Gets Overwritten
```bash
# Restore your custom config
~/.config/hypr/restore-config.sh
```

### Missing Packages
```bash
# Update and reinstall
nix-channel --update
home-manager switch
```

### GPU Issues
The environment variables are set to work with AMD GPUs by default. For other GPUs:
- **Intel**: Usually works out of the box
- **NVIDIA**: You may need additional drivers

This setup ensures your Hyprland environment is identical and robust across all your machines! 🎉