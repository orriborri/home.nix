{ lib, pkgs, ... }:

{
  # COSMIC desktop integration for Cosmic Atomic (ostree-based)
  # COSMIC provides its own compositor, settings, and app ecosystem.
  # This module adds complementary tools and environment configuration.

  home.packages = with pkgs; [
    # Wayland utilities (COSMIC is Wayland-native)
    wl-clipboard
    wayshot
    slurp

    # XDG portal support (COSMIC uses its own portal but xdg-utils is still useful)
    xdg-utils
  ];

  # COSMIC uses its own terminal (cosmic-term) and app launcher,
  # but we still want our Nix-managed tools accessible via PATH.
  home.sessionVariables = {
    # Ensure Wayland backends for Qt/GTK apps launched from Nix
    QT_QPA_PLATFORM = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    NIXOS_OZONE_WL = "1";
  };
}
