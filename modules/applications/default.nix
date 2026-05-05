{ pkgs, lib, config, ... }:

{
  imports = [
    ./cli
    ./gui
    ./neovim.nix
  ];
}
