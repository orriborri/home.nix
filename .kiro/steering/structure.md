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
│   ├── default.nix       # Module aggregator (imports applications, feature, service)
│   │
│   ├── applications/     # Application configurations
│   │   ├── default.nix   # Imports cli/ and gui/
│   │   ├── cli/          # Command-line tools
│   │   │   ├── default.nix   # CLI module entry point (programs config)
│   │   │   ├── zsh.nix       # Zsh shell configuration
│   │   │   ├── starship.nix  # Starship prompt
│   │   │   ├── atuin.nix     # Shell history
│   │   │   ├── zoxide.nix    # Directory navigation
│   │   │   ├── carapace.nix  # Completion generator
│   │   │   ├── direnv.nix    # Environment loader
│   │   │   ├── git.nix       # Git configuration
│   │   │   ├── gitui.nix     # Git TUI
│   │   │   ├── neovim.nix    # Neovim editor
│   │   │   ├── lsd.nix       # Better ls
│   │   │   └── htop.nix      # Process viewer
│   │   └── gui/          # Graphical applications
│   │       ├── default.nix   # GUI module entry point
│   │       ├── alacritty.nix # Alacritty terminal
│   │       ├── wezterm.nix   # Wezterm terminal
│   │       └── zellij.nix    # Terminal multiplexer
│   │
│   ├── desktop/          # Desktop environment configuration
│   │   ├── default.nix   # Desktop module entry point
│   │   ├── utils/        # Desktop utilities
│   │   │   ├── default.nix
│   │   │   └── waybar/   # Waybar status bar configurations
│   │   │       ├── waybar.nix
│   │   │       ├── powerline.nix
│   │   │       ├── mechabar.nix
│   │   │       ├── waybar-backup.nix
│   │   │       └── *.jsonc, *.css, *.sh
│   │   └── windowManager/  # Window manager configurations
│   │       └── sway/       # Sway window manager
│   │           ├── default.nix
│   │           └── swaysome.py
│   │
│   ├── feature/          # Switchable features (packages, env vars, config)
│   │   ├── default.nix   # Imports all features
│   │   ├── development.nix  # Dev packages and environment
│   │   ├── utilities.nix    # System utility packages and aliases
│   │   └── security.nix     # GPG, SSH, password management
│   │
│   └── service/          # Daemons and services
│       ├── default.nix   # Service module entry point
│       └── gpg-agent.nix # GPG agent service
│
├── lib/                  # Custom library functions
│   └── powerline.nix     # Powerline helpers for Waybar
│
├── overlays/             # Nixpkgs overlays
│   └── nodejs.nix        # Node.js version override
│
├── packages/             # Custom package definitions
│   ├── kiro.nix          # Kiro IDE Home Manager module
│   └── kiro-package.nix  # Kiro IDE standalone package
│
├── nixos/                # NixOS-specific configuration
│   ├── README.md
│   └── configuration.nix
│
├── templates/            # Flake templates
│   └── minimal/          # Minimal Home Manager template
│
└── .kiro/                # Kiro IDE configuration
    └── steering/         # AI assistant steering rules
```

## Architecture Patterns

### Module Organization (tiredofit-inspired)

Modules are organized by concern:
- `applications/`: Per-program configurations split into `cli/` and `gui/`
- `feature/`: Cross-cutting features (dev tools, utilities, security)
- `service/`: System services and daemons
- `desktop/`: Desktop environment (utils, window managers)

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
- `homeModules`: Reusable modules for other flakes
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
- Organized by concern: `applications/`, `feature/`, `service/`, `desktop/`
- Each module has a `default.nix` entry point
- Sub-modules named after the tool they configure

## Configuration Flow

1. `flake.nix` defines inputs and outputs
2. `home.nix` is the main entry point
3. System detection determines platform-specific behavior
4. `modules/applications/` configures individual programs (cli + gui)
5. `modules/feature/` adds cross-cutting packages and environment config
6. `modules/service/` manages daemons (gpg-agent, etc.)
7. `modules/desktop/windowManager/sway/` is conditionally imported for Sway
8. Overlays modify package versions (e.g., Node.js)
9. Custom libraries provide helper functions (e.g., powerline)

## Best Practices

- Keep modules focused on a single concern
- Use system detection for cross-platform compatibility
- Pass required arguments explicitly to modules
- Document complex configurations with comments
- Use `lib.optionals` for conditional lists
- Export reusable modules via flake outputs
- Maintain consistent formatting with `nix fmt`
- Place program configs in `applications/cli/` or `applications/gui/`
- Place package lists and env vars in `feature/`
- Place services/daemons in `service/`
