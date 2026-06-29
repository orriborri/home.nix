{ pkgs, claude-desktop, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
in
{
  imports = [ claude-desktop.homeManagerModules.default ];

  programs.claude-desktop = {
    enable = true;
    fhs = true;
    createDesktopEntry = true;
  };
}
