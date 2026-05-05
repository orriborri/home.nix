# Fedora Silverblue Setup

## 1. Install Nix (Determinate Systems installer for ostree)

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install ostree
```

Reboot after installation.

## 2. Install Home Manager

```bash
nix run home-manager -- switch --flake ~/.config/home-manager
```

## 3. Sway on Silverblue

Option A — Use Nix-managed sway (already in config, no rpm-ostree needed):
```bash
# Just log out and select "Sway" from the session picker
# (home-manager installs sway into ~/.nix-profile/bin)
```

Option B — Layer sway via rpm-ostree (if you prefer system-level):
```bash
rpm-ostree install sway swaybg swayidle swaylock
systemctl reboot
```

If using Option B, revert the swaylock paths back to `/usr/bin/swaylock`.

## 4. GUI Apps via Flatpak

```bash
flatpak install flathub org.mozilla.firefox
flatpak install flathub md.obsidian.Obsidian
flatpak install flathub com.onepassword.OnePassword
```

## 5. Development (toolbox for project-specific work)

```bash
toolbox create dev
toolbox enter dev
# Inside: install project-specific deps with dnf
```

Or just use `nix develop` / `devbox` as you already do.

## What's managed where

| Layer | Manages |
|-------|---------|
| Silverblue (immutable) | Kernel, GNOME, system services, PipeWire, NetworkManager |
| Nix + home-manager | Shell, CLI tools, dev tools, terminal configs, sway, waybar |
| Flatpak | GUI applications (Firefox, Obsidian, 1Password) |
| toolbox/distrobox | Project-specific development environments |
