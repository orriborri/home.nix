{ pkgs, lib, config, ... }:

{
  imports = [
    ./shell
    ./development
    ./utilities.nix
    ./security.nix
  ];
}