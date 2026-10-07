# NixOS Configuration

## Setup

The only NixOS host is the KiroCrew EC2 gateway (`kirocrew-ec2.nix`); the
`kirocrew` VM profile exists for local testing. See `kirocrew.md`.

Rebuild on the host: `sudo nixos-rebuild switch --flake ~/.config/home-manager#kirocrew-ec2`

## On Fedora

Use standalone Home Manager: `home-manager switch --flake ~/.config/home-manager`
