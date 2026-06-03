# Fedora Silverblue Setup

## Philosophy

| Layer | Manages |
|-------|---------|
| ostree (immutable) | Kernel, GNOME, system services, PipeWire, NetworkManager, GDM |
| Nix + home-manager | Shell, CLI tools, dev tools, terminal configs, dotfiles |
| Flatpak | GUI applications (Firefox, Obsidian, 1Password, Slack) |

Zero rpm-ostree layering — the base image stays untouched.

## 1. Install Nix (Determinate Systems installer for ostree)

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install ostree
```

Reboot after installation.

## 2. Apply Home Manager configuration

```bash
git clone https://github.com/orriborri/home.nix.git ~/.config/home-manager
cd ~/.config/home-manager
nix run home-manager -- switch --flake .
```

## 3. GUI Apps via Flatpak

```bash
flatpak install flathub org.mozilla.firefox
flatpak install flathub md.obsidian.Obsidian
flatpak install flathub com.onepassword.OnePassword
flatpak install flathub com.slack.Slack
```

## 4. Development environments

Use `nix develop` / `devbox` for project-specific toolchains, or toolbox for heavier needs:

```bash
toolbox create dev
toolbox enter dev
```
