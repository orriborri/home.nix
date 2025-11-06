# NixOS Configuration

## Setup

1. Copy this to `/etc/nixos/configuration.nix` or import it
2. Generate hardware config: `nixos-generate-config`
3. Add hardware import to configuration.nix:
   ```nix
   imports = [ ./hardware-configuration.nix ];
   ```
4. Rebuild: `sudo nixos-rebuild switch --flake ~/.config/home-manager#default`

## On Fedora

Use standalone Home Manager: `home-manager switch --flake ~/.config/home-manager`
