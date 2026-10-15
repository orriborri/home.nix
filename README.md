# Home Manager Configuration

Modern, secure, and well-structured Home Manager configuration for cross-platform development environments using **Nix Flakes**.

## Features

- **Flake-based**: Reproducible builds with lockfile, composable modules, and multi-system support
- **Multi-system support**: Works on NixOS, Fedora, Ubuntu, Arch, macOS, and other platforms
- **Modular architecture**: Clean separation of concerns with organized modules
- **Security-focused**: GPG, SSH hardening, and secure defaults
- **Development-ready**: Comprehensive tooling for modern development workflows
- **Reusable**: Export modules and packages for use in other flakes
- **Cross-platform compatibility**: Adapts to different operating systems automatically

## Quick Start

### Personal and Work Laptops

Both profiles share the shell, editor, development tools, and Kiro IDE and keep
the desktop supplied by the operating system.

```bash
./update.sh                   # Select using this machine's hostname
./update.sh --profile work    # Explicit override
./update.sh --profile work --update
```

`config/host-profiles` maps short hostnames (from `hostname -s`) to `personal`
or `work`, one pair per line. `workTop` maps to `work`; `orrTop` (also matched
as `orrtop`) maps to `personal`. Unlisted hosts default to `personal`.
`HOME_MANAGER_PROFILE` overrides the hostname mapping, and `--profile`
overrides both.

The `orre-personal` Home Manager profile disables ReadPeak repository cloning,
repository indexing, and KiroCrew services. Existing checkout directories are
left on disk.

The `orre-work` profile retains the existing work setup; `orre` remains its
compatibility alias. To switch directly without the update script:

```bash
nix run --inputs-from . home-manager -- switch --flake .#orre-personal -b backup
```

### Using Flakes

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
├── home.nix                  # Main entry point: imports all tool files
├── FLAKES.md                 # Comprehensive flakes guide
│
│   # Per-tool configs live flat at the root (FruitieX-style), imported by home.nix
├── zsh.nix  git.nix  neovim.nix  starship.nix  …   # one file per tool
├── development.nix           # Dev packages and environment
├── utilities.nix             # System utilities and aliases
├── security.nix              # GPG, SSH, password management
├── gpg-agent.nix             # GPG agent service
├── cosmic.nix                # COSMIC desktop integration
│
├── packages/                # Custom package definitions
│   ├── kiro.nix             # Kiro IDE Home Manager module
│   ├── claude-desktop.nix   # Claude Desktop (from llm-agents)
│   └── aidlc.nix            # aidlc CLI package
├── templates/               # Flake templates
│   └── minimal/             # Minimal starter template
└── nixos/                   # NixOS-specific configuration
```

## Flake Outputs

This repository exports multiple outputs for reuse:

### Home Configurations
- `orre` - Full workstation configuration for x86_64 Linux
- `orre@cosmic` - `orre` plus the COSMIC desktop integration
- `orre@aarch64` - `orre` for aarch64 Linux
- `orre@darwin` - macOS configuration
- `devcontainer`, `devcontainer-arm` - headless profiles for dev containers

### NixOS Configurations
- `kirocrew` - QEMU VM profile for local testing
- `kirocrew-ec2` - the KiroCrew EC2 gateway (see `nixos/kirocrew.md`)

### Packages
- `kirocrew-ami` - EC2 AMI image of `kirocrew-ec2`

### Modules (Reusable)
- `default` - the full home configuration as a module
- `kiro` - Kiro IDE

### Templates
- `minimal` - Bootstrap a new Home Manager config

See [FLAKES.md](./FLAKES.md) for detailed usage.

## Using This Configuration in Your Own Flake

Import modules or packages:

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
        home-nix.homeModules.kiro
        
        # Your config
        ./home.nix
      ];
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
- Structured, modular configuration

### Code Quality
- EditorConfig for consistent formatting
- Modular architecture for maintainability
- Proper error handling and validation
- Documentation and comments

## Customization

### Adding New Modules
1. Create a `<tool>.nix` at the repo root
2. Wire it into `home.nix` (assign under `programs` for function-style, or add
   to the `imports` list for module-style)
3. Configure any necessary options

### System-Specific Configuration
The configuration automatically detects your system and applies appropriate settings:
- Linux-specific packages and services
- macOS compatibility layers
- NixOS integration

### Security Configuration
- Configure GPG signing: Set your GPG key ID in `git.nix`
- SSH keys: Add your SSH configuration to `security.nix`
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
home-manager switch --flake .#orre@cosmic

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
