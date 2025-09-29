{ config, pkgs, ... }:
{
  home.packages = [ pkgs.waybar pkgs.waybar-hyprland-workspaces ];
  xdg.configFile."waybar/config.jsonc".source = ./waybar/config.jsonc;
}
