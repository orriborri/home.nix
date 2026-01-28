# Minimal Home Manager Template

A minimal starting point for Home Manager with Nix flakes.

## Quick Start

1. Copy this template:
   ```bash
   nix flake init -t github:orriborri/home.nix#minimal
   ```

2. Edit `home.nix` to set your username and home directory

3. Apply the configuration:
   ```bash
   home-manager switch --flake .
   ```

## Customization

Add more packages to `home.packages` or enable additional programs in `home.nix`.
