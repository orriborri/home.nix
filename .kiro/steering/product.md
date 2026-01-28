# Product Overview

This is a Home Manager configuration repository for managing cross-platform development environments using Nix.

## Purpose

Provides a modular, portable, and reproducible development environment that works across:
- NixOS systems
- Non-NixOS Linux distributions (Fedora, Ubuntu, Arch, etc.)
- macOS (Darwin)

## Key Features

- **Modular architecture**: Organized into logical modules (shell, development, desktop, utilities, security)
- **Cross-platform compatibility**: Automatically detects and adapts to different operating systems
- **Security-focused**: Includes GPG, SSH hardening, and secure defaults
- **Development-ready**: Comprehensive tooling for modern development workflows
- **Window manager support**: Sway configuration with structured configs
- **Reproducible**: Uses Nix flakes for deterministic builds

## Target Users

Developers who want:
- Consistent development environments across multiple machines
- Declarative configuration management
- Easy onboarding to new systems
- Version-controlled dotfiles and system configuration
