{ config, pkgs, ... }:
{
  home.packages = [ pkgs.hyprland ];
  xdg.configFile."hypr/hyprland.conf".source = ./hyprland.conf;
}
