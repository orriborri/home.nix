# Home Manager Configuration

Modern, secure, and well-structured Home Manager configuration for cross-platform development environments.

## Features

- **Multi-system support**: Works on NixOS, Fedora, Ubuntu, Arch, and other Linux distributions
- **Modular architecture**: Clean separation of concerns with organized modules
- **Security-focused**: GPG, SSH hardening, and secure defaults
- **Development-ready**: Comprehensive tooling for modern development workflows
- **Window manager support**: Sway configuration with structured configs
- **Cross-platform compatibility**: Adapts to different operating systems automatically

## Quick Start

### One-Line Installation

```bash
curl -fsSL https://raw.githubusercontent.com/orriborri/home.nix/main/setup.sh | bash
```

### Manual Installation

1. **Install Nix package manager**:
   ```bash
   sh <(curl -L https://nixos.org/nix/install) --daemon
   ```

2. **Install Home Manager**:
   ```bash
   nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
   nix-channel --update
   nix-shell '<home-manager>' -A install
   ```

3. **Clone and apply configuration**:
   ```bash
   git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager
   cd ~/.config/home-manager
   home-manager switch
   ```

## Configuration Structure

```
├── flake.nix                 # Flake configuration with multi-system support
├── home.nix                  # Main configuration entry point
├── modules/
│   ├── default.nix          # Module aggregator
│   ├── development/         # Development tools and languages
│   ├── shell/               # Shell configuration (zsh, starship, etc.)
│   ├── security.nix         # Security tools and hardening
│   ├── utilities.nix        # System utilities and tools
│   ├── desktop/             # Desktop applications
│   └── wm/                  # Window manager configurations
│       └── sway/            # Sway window manager
├── overlays/                # Nixpkgs overlays
├── lib/                     # Custom library functions
└── scripts/                 # Utility scripts
```

## Key Improvements

### Security Enhancements
- GPG configuration with modern algorithms
- SSH hardening with secure ciphers and key exchange
- Password management with `pass`
- Secure Git configuration with URL rewrites

### Development Environment
- Modern shell with zsh, starship, and useful plugins
- Comprehensive Git configuration with helpful aliases
- Development tools: Node.js, Python, Nix tooling
- Better terminal experience with foot and zellij

### System Integration
- Cross-platform package management
- Proper XDG configuration
- System detection and adaptive configuration
- Structured window manager configurations

### Code Quality
- EditorConfig for consistent formatting
- Modular architecture for maintainability
- Proper error handling and validation
- Documentation and comments

## Window Manager Support

### Sway (Default)
- Structured configuration with separate config modules
- Multi-monitor support with Kanshi
- Custom scripts for workspace management
- Screenshot utilities and display management

Switch between window managers by changing the `windowManager` variable in `home.nix` (currently supports Sway).

## Customization

### Adding New Modules
1. Create your module in the appropriate directory
2. Add it to `modules/default.nix`
3. Configure any necessary options

### System-Specific Configuration
The configuration automatically detects your system and applies appropriate settings:
- Linux-specific packages and services
- macOS compatibility layers
- NixOS integration

### Security Configuration
- Configure GPG signing: Set your GPG key ID in `modules/development/git.nix`
- SSH keys: Add your SSH configuration to `modules/security.nix`
- Password store: Initialize with `pass init <gpg-key-id>`

## Development

### Building and Testing
```bash
# Build configuration
home-manager build

# Apply configuration
home-manager switch

# Check for issues
nix flake check
```

### Formatting
```bash
# Format Nix files
nixfmt **/*.nix
```

## Troubleshooting

### Common Issues
- **Config overwrites**: Run the restore script if system packages overwrite configs
- **Missing packages**: Update channels with `nix-channel --update`
- **Permission issues**: Ensure proper file permissions for scripts

### Getting Help
- Check the Home Manager manual: https://nix-community.github.io/home-manager/
- Review module documentation in each directory
- Check system logs for service issues

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes following the existing patterns
4. Test thoroughly on your system
5. Submit a pull request

## License

This configuration is provided as-is for educational and personal use. Adapt as needed for your environment. 
