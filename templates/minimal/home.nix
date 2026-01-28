{ pkgs, ... }:

{
  home = {
    username = "user";
    homeDirectory = "/home/user";
    stateVersion = "24.05";
  };

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    git
    neovim
    zsh
  ];

  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "your.email@example.com";
  };

  programs.zsh.enable = true;
}
