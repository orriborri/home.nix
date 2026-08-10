# Project Structure

## Directory Organization

```
.
├── flake.nix              # Flake configuration with multi-system support
├── flake.lock             # Lockfile for reproducible builds
├── home.nix               # Main entry point: imports all tool files + program config
├── home-cosmic.nix        # COSMIC profile = home.nix + cosmic.nix
├── setup.sh               # One-line installation script
├── update.sh              # Update script
├── .editorconfig          # Editor configuration for consistent formatting
│
│   # Per-tool configs live flat at the repo root (FruitieX-style) and are
│   # imported directly by home.nix — no modules/ hierarchy, no aggregators.
├── zsh.nix                # Zsh shell configuration
├── starship.nix           # Starship prompt
├── atuin.nix              # Shell history
├── zoxide.nix             # Directory navigation
├── carapace.nix           # Completion generator
├── direnv.nix             # Environment loader
├── git.nix                # Git configuration
├── gitui.nix              # Git TUI
├── lazygit.nix            # Git TUI
├── neovim.nix             # Neovim editor (module)
├── neovim-config.nix      # Neovim programs config (function, assigned in home.nix)
├── lsd.nix                # Better ls
├── htop.nix               # Process viewer
├── zellij.nix             # Terminal multiplexer
├── zellij-layout.nix      # Zellij layout (module)
├── alacritty.nix          # Alacritty terminal
├── wezterm.nix            # Wezterm terminal
├── foot.nix               # Foot terminal (module)
├── cosmic.nix             # COSMIC desktop integration
├── development.nix        # Dev packages and environment
├── utilities.nix          # System utility packages and aliases
├── security.nix           # GPG, SSH, password management
├── gpg-agent.nix          # GPG agent service
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

### Layout (flat, FruitieX-style)

Per-tool configs live as individual `.nix` files at the repo root — no
`modules/` tree and no `default.nix` aggregators. `home.nix` is the single
aggregation point: it imports the module-style files and assigns the
function-style ones under `programs`.

- Program configs: one file per tool (`zsh.nix`, `git.nix`, `neovim.nix`, …)
- Cross-cutting features: `development.nix`, `utilities.nix`, `security.nix`
- Services/daemons: `gpg-agent.nix`
- Desktop: `cosmic.nix` (pulled in by the `orre@cosmic` profile)

### Two file idioms

- **Function-style** (most CLI/GUI tools): the file is a function returning a
  `programs.<name>` value, assigned in `home.nix`:
  ```nix
  programs.zsh = (import ./zsh.nix { inherit pkgs lib config; });
  ```
- **Module-style** (`neovim.nix`, `foot.nix`, `zellij-layout.nix`, the feature
  and service files): a normal Home Manager module, pulled in via `home.nix`'s
  `imports = [ ./neovim.nix ./development.nix … ]`.

The `orre@cosmic` profile is `home-cosmic.nix`, which simply composes
`imports = [ ./home.nix ./cosmic.nix ]`.

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
2. `home.nix` is the main entry point — imports the flat module files and
   assigns the function-style tool configs under `programs`
3. System detection determines platform-specific behavior
4. Per-tool files at the repo root configure individual programs
5. `development.nix` / `utilities.nix` add cross-cutting packages and env config
6. `gpg-agent.nix` manages the GPG agent daemon
7. `cosmic.nix` adds COSMIC desktop integration (used by the `orre@cosmic` profile)
8. Overlays modify package versions (e.g., Node.js)

## Best Practices

- Keep modules focused on a single concern
- Use system detection for cross-platform compatibility
- Pass required arguments explicitly to modules
- Document complex configurations with comments
- Use `lib.optionals` for conditional lists
- Export reusable modules via flake outputs
- Maintain consistent formatting with `nix fmt`
- Place each program's config in its own root-level `<tool>.nix`
- Add it to `home.nix` (assign under `programs` for function-style, or to the
  `imports` list for module-style)
- Place package lists and env vars in `development.nix` / `utilities.nix`
- Place services/daemons in their own root file (e.g., `gpg-agent.nix`)
