{ pkgs, ... }:

{
  programs.foot = {
    enable = true;
    settings = {
      main = {
        shell = "${pkgs.zsh}/bin/zsh";
        login-shell = "yes";
        font = "JetBrainsMono Nerd Font:size=12";
      };
      csd = {
        preferred = "none";
      };
      environment = {
        PATH = "/home/orre/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      };
      colors = {
        # Dracula theme
        background = "282a36";
        foreground = "f8f8f2";
      };
    };
  };
}
