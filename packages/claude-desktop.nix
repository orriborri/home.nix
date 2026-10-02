{ pkgs, claude-desktop, ... }:
{
  imports = [ claude-desktop.homeManagerModules.default ];

  programs.claude-desktop = {
    enable = true;
    fhs = true;
    createDesktopEntry = true;
  };
}
