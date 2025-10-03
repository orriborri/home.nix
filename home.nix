{ pkgs, lib, ... }:
{


  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "orre";
  home.homeDirectory = "/home/orre";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "obsidian"
  ];
  nixpkgs.config.permittedInsecurePackages = [];
  nixpkgs.overlays = [
    (final: prev: {
      nodejs = prev.nodejs;
    })
  ];
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    gitAndTools.gh
  ];

  programs = {
    home-manager.enable = true;
  };


  imports = [
    ./modules/shell
    ./modules/development
    ./modules/desktop
    ./modules/utilities.nix
  ];
}
