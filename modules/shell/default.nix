{ pkgs, ... }:

{
  programs = {
    zsh = (import ../../zsh.nix { inherit pkgs; });
    starship = (import ../../starship.nix { inherit pkgs; });
    direnv = (import ../../direnv.nix { inherit pkgs; });
    zoxide = (import ../../zoxide.nix { inherit pkgs; });
    carapace = (import ../../carapace.nix { inherit pkgs; });
    atuin = (import ../../atuin.nix { inherit pkgs; });
    nushell = (import ../../nushell.nix { inherit pkgs; });
  };
}