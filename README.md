# Home Manager Configuration

Modern, secure, and well-structured Home Manager configuration for cross-platform development environments using **Nix Flakes**.

## Features

- **Flake-based**: Reproducible builds with lockfile, composable modules, and multi-system support
- **Multi-system support**: Works on NixOS, Fedora, Ubuntu, Arch, macOS, and other platforms
- **Modular architecture**: Clean separation of concerns with organized modules
- **Security-focused**: GPG, SSH hardening, and secure defaults
- **Development-ready**: Comprehensive tooling for modern development workflows
- **Window manager support**: Sway configuration with structured configs
- **Reusable**: Export modules, overlays, and packages for use in other flakes
- **Cross-platform compatibility**: Adapts to different operating systems automatically

## Quick Start

### One-Line Installation

```bash
curl -fsSL https://raw.githubusercontent.com/orriborri/home.nix/main/setup.sh | bash
```

### Using Flakes (Recommended)

1. **Install Nix with flakes enabled**:
   ```bash
   sh <(curl -L https://nixos.org/nix/install) --daemon
   
   # Enable flakes
   mkdir -p ~/.config/nix
   echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
   ```

2. **Clone and apply configuration**:
   ```bash
   git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager
   cd ~/.config/home-manager
   nix run nixpkgs#home-manager -- switch --flake .
   ```

### Bootstrap from Template

Start with a minimal configuration:

```bash
nix flake init -t github:orriborri/home.nix#minimal
# Edit home.nix with your details
home-manager switch --flake .
```

## Configuration Structure

```
├── flake.nix                 # Flake configuration with multi-system support
├── flake.lock                # Lockfile for reproducible builds
├── home.nix                  # Main configuration entry point
├── FLAKES.md                 # Comprehensive flakes guide
├── modules/
│   ├── default.nix          # Module aggregator
│   ├── development/         # Development tools and languages
│   ├── shell/               # Shell configuration (zsh, starship, etc.)
│   ├── security.nix         # Security tools and hardening
│   ├── utilities.nix        # System utilities and tools
│   ├── desktop/             # Desktop applications
│   └── wm/                  # Window manager configurations
│       └── sway/            # Sway window manager
├── lib/                     # Custom library functions
│   └── powerline.nix        # Powerline helpers for Waybar
├── overlays/                # Nixpkgs overlays
│   └── nodejs.nix           # Node.js version override
├── packages/                # Custom package definitions
│   ├── kiro.nix             # Kiro IDE Home Manager module
│   └── kiro-package.nix     # Kiro IDE standalone package
├── templates/               # Flake templates
│   └── minimal/             # Minimal starter template
└── nixos/                   # NixOS-specific configuration
```

## Flake Outputs

This repository exports multiple outputs for reuse:

### Home Configurations
- `orre` - Full configuration for Linux
- `orre@darwin` - macOS configuration
- `orre-minimal` - Minimal config without desktop environment

### Packages
- `kiro-ide` - Kiro AI IDE (x86_64-linux)

### Modules (Reusable)
- `shell` - zsh, starship, atuin, zoxide
- `development` - git, neovim, dev tools
- `desktop` - terminals, multiplexers
- `security` - GPG, SSH hardening
- `utilities` - system utilities
- `sway` - Sway window manager
- `kiro` - Kiro IDE

### Overlays
- `nodejs` - Latest Node.js version
- `default` - All overlays combined

### Libraries
- `powerline` - Waybar powerline helpers

### Templates
- `minimal` - Bootstrap a new Home Manager config

See [FLAKES.md](./FLAKES.md) for detailed usage.

## Using This Configuration in Your Own Flake

Import modules, overlays, or packages:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-nix = {
      url = "github:orriborri/home.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, home-nix, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        # Import specific modules
        home-nix.homeManagerModules.shell
        home-nix.homeManagerModules.development
        
        # Your config
        ./home.nix
      ];
      
      # Use overlays
      nixpkgs.overlays = [ home-nix.overlays.nodejs ];
    };
  };
}
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
# Validate flake configuration
nix flake check

# Show all flake outputs
nix flake show

# Format all Nix files
nix fmt

# Build configuration without applying
home-manager build --flake .

# Apply configuration
home-manager switch --flake .

# Apply specific configuration
home-manager switch --flake .#orre-minimal

# Update flake inputs
nix flake update

# Update and apply in one command
nix run .#update
```

### Development Environment
```bash
# Enter development shell
nix develop

# Enter test shell with additional tools
nix develop .#test
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
