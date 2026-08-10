{ lib, ... }:

# Declarative GUI apps via Flatpak (nix-flatpak).
# The nix-flatpak home-manager module itself is imported at the flake level
# (in mkHome's extraModules) to avoid the known HM nested-import recursion.
#
# Model note: Flatpaks are convergent, NOT reproducible — they live outside the
# Nix store (~/.local/share/flatpak) and track upstream. Nix owns the CLI;
# Flatpak owns the GUI.
{
  services.flatpak = {
    enable = true;

    # flathub is added by default; declared explicitly so it's obvious.
    remotes = [
      {
        name = "flathub";
        location = "https://flathub.org/repo/flathub.flatpakrepo";
      }
    ];

    # Your GUI apps. Add more app IDs here (find them on flathub.org).
    packages = [
      # Productivity
      "md.obsidian.Obsidian"
      "io.dbeaver.DBeaverCommunity"
      "com.bitwarden.desktop"

      # Migrated from dnf (third-party apps; Fedora defaults stay as RPM)
      "com.slack.Slack"
      "com.google.Chrome"
      "org.chromium.Chromium"
      "im.nheko.Nheko"
      "org.videolan.VLC"
    ];

    # NOTE: uninstallUnmanaged is intentionally left at its default (false) so
    # this does NOT remove Flatpaks you installed by hand. Set it to true only
    # once every GUI app you use is listed above, or it will uninstall the rest.
    # uninstallUnmanaged = true;

    # Track upstream weekly (Flatpak's convergent model). Comment out to pin.
    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };
  };

  # Convenience aliases so the short command names still work.
  home.shellAliases = {
    obsidian = "flatpak run md.obsidian.Obsidian";
    dbeaver = "flatpak run io.dbeaver.DBeaverCommunity";
    bitwarden = "flatpak run com.bitwarden.desktop";
  };
}
