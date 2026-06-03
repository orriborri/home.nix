# Fedora Silverblue Setup

## Philosophy

| Layer | Manages |
|-------|---------|
| ostree (immutable) | Kernel, GNOME, system services, PipeWire, NetworkManager, GDM |
| rpm-ostree (layered) | System daemons that need root (tailscale, howdy) |
| Nix + home-manager | Shell, CLI tools, dev tools, terminal configs, dotfiles |
| Flatpak | GUI applications |
| nix develop / toolbox | Project-specific toolchains (compilers, runtimes) |

Goal: zero or minimal rpm-ostree layering.

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

## 3. Layered packages (only what needs system-level access)

```bash
rpm-ostree install tailscale howdy
systemctl reboot
```

## 4. Flatpak apps

```bash
flatpak install flathub org.mozilla.firefox
flatpak install flathub md.obsidian.Obsidian
flatpak install flathub com.onepassword.OnePassword
flatpak install flathub com.slack.Slack
flatpak install flathub com.valvesoftware.Steam
flatpak install flathub com.google.Chrome
flatpak install flathub org.videolan.VLC
flatpak install flathub io.dbeaver.DBeaverCommunity
flatpak install flathub com.bitwarden.desktop
flatpak install flathub org.freedesktop.Platform.VulkanLayer.gamescope
```

## 5. Development environments

Use `nix develop` for project-specific toolchains:

```bash
# Example: Rust project
nix develop nixpkgs#rustPlatform

# Example: Node.js project
nix develop nixpkgs#nodejs
```

Or toolbox for heavier needs:

```bash
toolbox create dev
toolbox enter dev
# dnf install gcc cmake meson cargo rust ...
```

## Migration checklist

### Already handled by Nix (home-manager)

- [x] git-filter-repo, git-lfs
- [x] feh
- [x] kitty
- [x] mqtt-cli
- [x] session-manager-plugin (AWS)
- [x] wdisplays
- [x] tigervnc (client)

### Already built-in on Silverblue

- [x] podman (replaces docker for most use cases)
- [x] toolbox
- [x] ptyxis (GNOME terminal)
- [x] gnupg2

### Move to Flatpak

- [x] 1password
- [x] chromium
- [x] slack
- [x] steam
- [x] vlc
- [x] DBeaver
- [x] wine → use Bottles flatpak instead

### Layer with rpm-ostree (needs system access)

- [ ] tailscale (system daemon)
- [ ] howdy (PAM/IR camera auth)

### Use nix develop / toolbox (not system-wide)

- gcc, g++, cmake, meson, cargo, rust
- dyalog

### Skip on Silverblue

- docker-ce → use podman (compatible CLI)
- sway, swaylock, waybar → not needed for now
- sddm → GDM is default
- virtualbox-guest-additions → not needed unless in VM
- code-insiders → use Kiro/Nix-managed editors
