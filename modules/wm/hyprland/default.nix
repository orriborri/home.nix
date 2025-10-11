{ config, pkgs, ... }:
{
  home.packages = with pkgs; [
    hyprland
  ];

  imports = [
    ../../desktop/waybar/waybar.nix
    ../../desktop/hyprland.nix
    ../../desktop/hyprlock/hyprlock.nix
    ../../desktop/hyprlogout/hyprlogout.nix
  ];
}