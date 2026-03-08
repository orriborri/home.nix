{ pkgs, lib, config, ... }:

{
  imports = [
    ./cli
    ./gui
    ./neovim.nix
    ./zellij-layout.nix
  ];
}
