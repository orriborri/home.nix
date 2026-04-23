# Display Management

## Architecture

- **nwg-displays** — GUI for arranging monitors (drag & drop)
- **Kanshi** — auto-switches display profiles on dock/undock
- **display-manager** — wofi script that bridges the two

Profiles are stored by nwg-displays in `~/.config/nwg-displays/profiles/*.json` and automatically converted to Kanshi format at `~/.config/kanshi/config`.

## Usage

### From wofi launcher
Type "Display Manager" in wofi (`Super+d`).

### From keybinding
`Super+F8` opens the display manager menu with options:
- **📐 Arrange displays** — opens nwg-displays, then syncs all profiles to Kanshi
- **🔄 Sync profiles to kanshi** — converts nwg-displays profiles without opening GUI
- **🖥 \<profile\>** — edit a specific profile, then sync

### Workflow
1. Open display manager (`Super+F8` or wofi)
2. Choose "Arrange displays"
3. Drag monitors in nwg-displays, save with a profile name
4. Close nwg-displays — profiles auto-sync to Kanshi
5. Kanshi auto-applies the matching profile on dock/undock

## Config locations

| Tool | Path | Managed by |
|------|------|------------|
| nwg-displays profiles | `~/.config/nwg-displays/profiles/*.json` | nwg-displays GUI |
| Kanshi config | `~/.config/kanshi/config` | display-manager (auto-generated) |
| Sway outputs | `~/.config/sway/outputs` | nwg-displays (included by sway config) |

## Notes

- Don't edit `~/.config/kanshi/config` manually — it's overwritten on sync
- Profile names are derived from nwg-displays filenames (lowercased, spaces → hyphens)
- Kanshi runs as a systemd user service, managed by Home Manager
