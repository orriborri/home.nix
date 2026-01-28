# Technology Stack

## Build System

- **Nix Flakes**: Modern Nix build system with lockfile for reproducibility
- **Home Manager**: Declarative user environment management
- **nixfmt-rfc-style**: Code formatter for Nix files

## Core Technologies

### Package Management
- Nix package manager (unstable and stable channels)
- Home Manager for user-level package management
- Overlays for custom package modifications

### Languages & Runtimes
- Node.js (latest version via overlay)
- Python (with uv package manager)
- Nix language for configuration

### Development Tools
- Neovim (text editor)
- Git with delta (diff viewer)
- gitui (terminal UI for git)
- nil/nixd (Nix LSP servers)
- direnv with nix-direnv (automatic environment loading)

### Shell Environment
- zsh (shell)
- starship (prompt)
- atuin (shell history)
- zoxide (smart directory navigation)
- carapace (completion generator)
- fzf (fuzzy finder)

### Desktop Environment (Linux)
- Sway (Wayland compositor)
- Waybar (status bar)
- Alacritty/Wezterm (terminals)
- Zellij (terminal multiplexer)

### Additional Tools
- Kiro IDE (AI-powered IDE)
- AWS CLI v2
- GitLab CI Local
- Devbox

## Common Commands

### Building & Testing
```bash
# Validate flake configuration
nix flake check

# Format all Nix files
nix fmt

# Build configuration without applying
home-manager build

# Apply configuration
home-manager switch

# Apply with specific flake configuration
home-manager switch --flake .

# Update flake inputs
nix flake update
```

### Development Environment
```bash
# Enter development shell
nix develop

# Enter test shell with additional tools
nix develop .#test
```

### Package Management
```bash
# Update channels
nix-channel --update

# Search for packages
nix search nixpkgs <package-name>

# Show package info
nix-env -qa <package-name>
```

### Debugging
```bash
# Show package dependency tree
nix-tree

# Show differences between configurations
nix-diff

# Check what will be built
nix build --dry-run
```

## File Formats

- `.nix`: Nix expression language files
- `.toml`: Configuration files (referenced in steering rules but not present in this repo)
- `.md`: Documentation files
- `.lock`: Flake lockfile for reproducible builds

## System Detection

The configuration automatically detects:
- `isNixOS`: Whether running on NixOS
- `isDarwin`: Whether running on macOS
- `isLinux`: Whether running on Linux

This enables conditional package installation and configuration.
