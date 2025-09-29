{ config, pkgs, ... }:
{
  home.packages = [ pkgs.hyprland ];
  xdg.configFile."hypr/hyprland.conf".source = ./hypr/hyprland.conf;
}
