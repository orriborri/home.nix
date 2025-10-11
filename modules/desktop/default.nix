{ pkgs, ... }:

{
  imports = [
    # hyprland.nix and waybar.nix are now in wm modules
    # ./hyprland.nix
    # ./waybar/waybar.nix
    ./hyprlock/hyprlock.nix
    ./hyprlogout/hyprlogout.nix
  ];

  programs = {
    wezterm = (import ./wezterm.nix { inherit pkgs; });
    zellij = (import ./zellij.nix { inherit pkgs; });
    
    foot = {
      enable = true;
      settings = {
        main = {
          shell = "zsh";
        };
      };
    };
    
    kitty = {
      enable = true;
      settings = {
      };
    };
  };

  home.packages = with pkgs; [
    obsidian
  ];
}