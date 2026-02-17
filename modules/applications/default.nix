{ pkgs, lib, config, ... }:

{
  imports = [
    ./cli
    ./gui
  ];
}
