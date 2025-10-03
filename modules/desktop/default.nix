{ pkgs, ... }:

{
  imports = [
    ../../hyprland.nix
    ../../waybar/waybar.nix
    ../../hyprlock/hyprlock.nix
    ../../hyprlogout/hyprlogout.nix
  ];

  programs = {
    wezterm = (import ../../wezterm.nix { inherit pkgs; });
    zellij = (import ../../zellij.nix { inherit pkgs; });
    
    foot = {
      enable = true;
      settings = {
        main = {
          shell = "zsh";
        };
      };
    };
  };

  home.packages = with pkgs; [
    obsidian
  ];
}