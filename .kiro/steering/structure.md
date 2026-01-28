# Project Structure

## Directory Organization

```
.
├── flake.nix              # Flake configuration with multi-system support
├── flake.lock             # Lockfile for reproducible builds
├── home.nix               # Main Home Manager configuration entry point
├── setup.sh               # One-line installation script
├── update.sh              # Update script
├── .editorconfig          # Editor configuration for consistent formatting
│
├── modules/               # Modular configuration components
│   ├── default.nix       # Module aggregator
│   ├── shell/            # Shell configuration (zsh, starship, atuin, etc.)
│   │   ├── default.nix   # Shell module entry point
│   │   ├── zsh.nix       # Zsh configuration
│   │   ├── starship.nix  # Starship prompt
│   │   ├── atuin.nix     # Shell history
│   │   ├── zoxide.nix    # Directory navigation
│   │   ├── carapace.nix  # Completion generator
│   │   └── direnv.nix    # Environment loader
│   │
│   ├── development/      # Development tools and languages
│   │   ├── default.nix   # Development module entry point
│   │   ├── git.nix       # Git configuration
│   │   ├── gitui.nix     # Git TUI
│   │   └── neovim.nix    # Neovim configuration
│   │
│   ├── desktop/          # Desktop applications and configuration
│   │   ├── default.nix   # Desktop module entry point
│   │   ├── alacritty.nix # Alacritty terminal
│   │   ├── wezterm.nix   # Wezterm terminal
│   │   ├── zellij.nix    # Terminal multiplexer
│   │   └── waybar/       # Waybar status bar configurations
│   │       ├── waybar.nix
│   │       ├── powerline.nix
│   │       ├── mechabar.nix
│   │       └── *.jsonc, *.css, *.sh
│   │
│   ├── wm/               # Window manager configurations
│   │   └── sway/         # Sway window manager
│   │       ├── default.nix
│   │       └── swaysome.py
│   │
│   ├── utilities.nix     # System utilities and tools
│   └── security.nix      # Security tools and hardening (GPG, SSH)
│
├── lib/                  # Custom library functions
│   └── powerline.nix     # Powerline helpers for Waybar
│
├── overlays/             # Nixpkgs overlays
│   └── nodejs.nix        # Node.js version override
│
├── packages/             # Custom package definitions
│   └── kiro.nix          # Kiro IDE package
│
├── nixos/                # NixOS-specific configuration
│   ├── README.md
│   └── configuration.nix
│
└── .kiro/                # Kiro IDE configuration
    └── steering/         # AI assistant steering rules
```

## Architecture Patterns

### Module Structure

Each module follows a consistent pattern:
- `default.nix`: Entry point that imports and configures sub-modules
- Individual `.nix` files for specific tools/programs
- Modules are imported via `imports = [ ./modules/... ]` in `home.nix`

### Configuration Imports

Modules use explicit imports with attribute passing:
```nix
programs.zsh = (import ./zsh.nix { inherit pkgs lib config; });
```

### System Detection

Platform-specific configuration uses conditional logic:
```nix
isNixOS = builtins.pathExists /etc/NIXOS;
isDarwin = pkgs.stdenv.isDarwin;
isLinux = pkgs.stdenv.isLinux;

# Conditional package installation
home.packages = with pkgs; [
  # Common packages
] ++ lib.optionals isLinux [
  # Linux-only packages
] ++ lib.optionals isDarwin [
  # macOS-only packages
];
```

### Flake Outputs

The flake exports multiple outputs:
- `overlays`: Custom package overlays (e.g., Node.js version)
- `homeManagerModules`: Reusable modules for other flakes
- `nixosModules`: NixOS system modules
- `homeConfigurations`: Pre-configured Home Manager profiles
- `devShells`: Development environments
- `formatter`: Code formatter (nixfmt-rfc-style)

### Special Arguments

Custom arguments passed to modules:
- `powerlineLib`: Custom library for Waybar powerline styling
- `pkgs-stable`: Stable channel packages alongside unstable

## Naming Conventions

### Files
- Module files: lowercase with hyphens (e.g., `starship.nix`)
- Configuration files: descriptive names (e.g., `configuration.nix`)
- Scripts: lowercase with `.sh` extension

### Variables
- camelCase for local variables (e.g., `homeDirectory`)
- lowercase for system detection flags (e.g., `isNixOS`)
- UPPERCASE for environment variables (e.g., `EDITOR`)

### Modules
- Organized by function: `shell/`, `development/`, `desktop/`, `wm/`
- Each module has a `default.nix` entry point
- Sub-modules named after the tool they configure

## Configuration Flow

1. `flake.nix` defines inputs and outputs
2. `home.nix` is the main entry point
3. System detection determines platform-specific behavior
4. Modules are imported conditionally based on configuration
5. Each module configures specific programs and packages
6. Overlays modify package versions (e.g., Node.js)
7. Custom libraries provide helper functions (e.g., powerline)

## Best Practices

- Keep modules focused on a single concern
- Use system detection for cross-platform compatibility
- Pass required arguments explicitly to modules
- Document complex configurations with comments
- Use `lib.optionals` for conditional lists
- Export reusable modules via flake outputs
- Maintain consistent formatting with `nix fmt`
