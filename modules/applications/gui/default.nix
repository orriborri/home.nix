{ pkgs, ... }:

{
  imports = [
    ./foot.nix
  ];

  programs = {
    wezterm = (import ./wezterm.nix { inherit pkgs; });
    alacritty = (import ./alacritty.nix { inherit pkgs; });

    kitty = {
      enable = true;
      settings = {
      };
    };
  };

  home.packages = with pkgs; [
    foot
    # obsidian  # Temporarily disabled — triggers full Electron/Chromium source build
  ];
}
