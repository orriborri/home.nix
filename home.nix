{ pkgs, lib, ... }:

let
  #windowManager = "hyprland"; # Change to "sway"
  windowManager = "sway"; # Change to "sway"
in
{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "orre";
  home.homeDirectory = "/home/orre";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "obsidian"
  ];
  nixpkgs.config.permittedInsecurePackages = [];
  nixpkgs.overlays = [
    (final: prev: {
      nodejs = prev.nodejs;
    })
  ];
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.05";

  home.packages = with pkgs; [
    gh
    power-profiles-daemon
    nerd-fonts.jetbrains-mono
    nerd-fonts.hack
    powerline-fonts
    font-awesome
    liberation_ttf
    emote
    devbox
    # Graphics and Wayland support
    mesa
    vulkan-loader
    vulkan-headers
    vulkan-tools
    libva
    libva-utils
  ];

  programs = {
    home-manager.enable = true;
  };

  imports =
    [
      ./modules/shell
      ./modules/development
      ./modules/utilities.nix
    ]
    ++ (
      if windowManager == "hyprland" then [
        ./modules/wm/hyprland/default.nix
        ./modules/desktop  # Keep non-waybar desktop modules
      ] else if windowManager == "sway" then [
        ./modules/wm/sway/default.nix
      ] else []
    );
}
