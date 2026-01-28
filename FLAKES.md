# Flakes Guide

This repository uses Nix flakes for reproducible, composable configuration management.

## What Are Flakes?

Flakes provide:
- **Reproducibility**: Lock file ensures identical builds across machines
- **Composability**: Import and reuse configurations from other flakes
- **Discoverability**: Standard outputs make it easy to find what's available
- **Multi-system support**: Single flake works across Linux, macOS, and different architectures

## Available Outputs

### Home Configurations

```bash
# Main configuration for Linux
home-manager switch --flake .#orre

# macOS configuration
home-manager switch --flake .#orre@darwin

# Minimal configuration (no desktop environment)
home-manager switch --flake .#orre-minimal
```

### Packages

```bash
# Build Kiro IDE package
nix build .#kiro-ide

# Run Kiro IDE directly
nix run .#kiro-ide
```

### Development Shells

```bash
# Enter default development shell
nix develop

# Enter test shell with additional debugging tools
nix develop .#test
```

### Modules (Reusable in Other Flakes)

Import individual modules in your own flake:

```nix
{
  inputs.home-nix.url = "github:orriborri/home.nix";
  
  outputs = { home-nix, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      modules = [
        home-nix.homeManagerModules.shell
        home-nix.homeManagerModules.development
        # ... your config
      ];
    };
  };
}
```

Available modules:
- `shell` - zsh, starship, atuin, zoxide, etc.
- `development` - git, neovim, development tools
- `desktop` - alacritty, wezterm, zellij
- `utilities` - system utilities
- `security` - GPG, SSH hardening
- `kiro` - Kiro IDE
- `sway` - Sway window manager

### Overlays

Use the Node.js overlay in your own flake:

```nix
{
  inputs.home-nix.url = "github:orriborri/home.nix";
  
  outputs = { nixpkgs, home-nix, ... }: {
    nixpkgs.overlays = [ home-nix.overlays.nodejs ];
  };
}
```

### Libraries

Access custom libraries:

```nix
{
  inputs.home-nix.url = "github:orriborri/home.nix";
  
  outputs = { home-nix, ... }: {
    # Use powerline helpers
    powerlineLib = home-nix.lib.powerline { inherit lib; };
  };
}
```

### Templates

Bootstrap a new configuration:

```bash
# Create minimal Home Manager config
nix flake init -t github:orriborri/home.nix#minimal
```

### Apps

Convenient commands via `nix run`:

```bash
# Apply home-manager configuration
nix run .#default

# Update flake and apply
nix run .#update
```

## Common Commands

### Building and Applying

```bash
# Check flake validity
nix flake check

# Show flake outputs
nix flake show

# Build without applying
home-manager build --flake .

# Apply configuration
home-manager switch --flake .

# Apply specific configuration
home-manager switch --flake .#orre-minimal
```

### Updating

```bash
# Update all inputs
nix flake update

# Update specific input
nix flake lock --update-input nixpkgs

# Update and apply
nix run .#update
```

### Formatting

```bash
# Format all Nix files
nix fmt
```

### Exploring

```bash
# Show what's in the flake
nix flake show

# Show flake metadata
nix flake metadata

# List all outputs
nix flake show --json | jq
```

## Using This Flake in Your Own Configuration

### As a Dependency

Add to your `flake.nix`:

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
        
        # Your custom config
        ./home.nix
      ];
    };
  };
}
```

### Using Overlays

```nix
{
  nixpkgs.overlays = [
    home-nix.overlays.nodejs
  ];
}
```

### Using Packages

```nix
{
  home.packages = [
    home-nix.packages.x86_64-linux.kiro-ide
  ];
}
```

## Multi-System Support

This flake supports:
- `x86_64-linux` - 64-bit Intel/AMD Linux
- `aarch64-linux` - 64-bit ARM Linux
- `x86_64-darwin` - 64-bit Intel macOS
- `aarch64-darwin` - Apple Silicon macOS

Most outputs are available for all systems, with some exceptions (e.g., Kiro IDE is Linux-only).

## Flake Structure

```
flake.nix
├── inputs          # Dependencies (nixpkgs, home-manager, etc.)
└── outputs
    ├── packages    # Standalone packages (kiro-ide)
    ├── overlays    # Package modifications (nodejs)
    ├── lib         # Custom libraries (powerline)
    ├── homeManagerModules  # Reusable modules
    ├── nixosModules        # NixOS modules
    ├── homeConfigurations  # Pre-built configs
    ├── devShells   # Development environments
    ├── formatter   # Code formatter
    ├── templates   # Bootstrap templates
    └── apps        # Convenient commands
```

## Tips

1. **Pin versions**: The `flake.lock` file ensures reproducibility. Commit it to git.

2. **Update regularly**: Run `nix flake update` periodically to get security updates.

3. **Test before applying**: Use `home-manager build --flake .` to test without applying.

4. **Use templates**: Start new configs with `nix flake init -t github:orriborri/home.nix#minimal`.

5. **Explore outputs**: Run `nix flake show` to see everything available.

6. **Format code**: Run `nix fmt` before committing to maintain consistency.

## Troubleshooting

### Flake not found
```bash
# Make sure you're in the directory with flake.nix
cd ~/.config/home-manager

# Or specify the path
home-manager switch --flake ~/.config/home-manager
```

### Experimental features not enabled
```bash
# Add to ~/.config/nix/nix.conf or /etc/nix/nix.conf
experimental-features = nix-command flakes
```

### Lock file conflicts
```bash
# Regenerate lock file
rm flake.lock
nix flake lock
```

### Build failures after update
```bash
# Rollback to previous version
nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/<commit-hash>
```

## Resources

- [Nix Flakes Manual](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/)
- [Flake Parts](https://flake.parts/) - Advanced flake composition
