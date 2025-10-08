{ pkgs, ... }:

{
  imports = [
    ./hyprland.nix
    ./waybar/waybar.nix
    ./hyprlock/hyprlock.nix
    ./hyprlogout/hyprlogout.nix
  ];

  programs = {
    wezterm = (import ./wezterm.nix { inherit pkgs; });
    zellij = (import ./zellij.nix { inherit pkgs; });
    
    zsh.enable = true;
    
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
      extraConfig = ''
        launch sh -c "ls && exec zsh"
      '';
    };
  };

  home.packages = with pkgs; [
    obsidian
    power-profiles-daemon
  ];
}