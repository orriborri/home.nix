{ pkgs, lib, config, ... }:

{
  imports = [
    ./gpg-agent.nix
  ];
}
