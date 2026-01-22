{ pkgs, ... }:

{
  imports = [
    # Desktop applications and configurations
    # waybar.nix is now in wm modules
  ];

  programs = {
    wezterm = (import ./wezterm.nix { inherit pkgs; });
    zellij = (import ./zellij.nix { inherit pkgs; });
    
    alacritty = (import ./alacritty.nix { inherit pkgs; });
    
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