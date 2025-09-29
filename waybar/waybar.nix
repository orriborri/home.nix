{ config, pkgs, ... }:
{
  home.packages = [ pkgs.waybar ];
  xdg.configFile."waybar/config.jsonc".source = ./config.jsonc;
}
