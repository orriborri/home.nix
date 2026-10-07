{ pkgs, ... }:

{
  home = {
    username = "user";
    homeDirectory = "/home/user";
    stateVersion = "26.05";
    packages = with pkgs; [
      git
      neovim
      zsh
    ];
  };

  programs = {
    home-manager.enable = true;
    git = {
      enable = true;
      userName = "Your Name";
      userEmail = "your.email@example.com";
    };
    zsh.enable = true;
  };
}
