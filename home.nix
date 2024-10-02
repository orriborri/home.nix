{ config, pkgs, ... }:

{
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "orre";
  home.homeDirectory = "/home/orre";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "21.05";

  home.packages = with pkgs; [
    coreutils
    less # Non busybox version of less needed by delta
    ripgrep
    jq
    unzip
    ncdu
    strace
    binutils
    tokei
    xh
    jc
    zoxide
    xclip
    eza
    carapace
    gitAndTools.gh
    nodejs_20

    cargo
    rustc
    pre-commit
    pinentry
  ];

  programs = {
    neovim = (import ./neovim.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs; });
    tmux = (import ./tmux.nix { inherit pkgs; });
    zsh = (import ./zsh.nix { inherit pkgs; });
    starship = (import ./starship.nix { inherit pkgs; });
    direnv = (import ./direnv.nix { inherit pkgs; });
    htop = (import ./htop.nix { inherit pkgs; });
    nushell = (import ./nushell.nix { inherit pkgs; });
    gpg = (import ./gpg.nix { inherit pkgs; });
  };
  programs.gpg-agent.extraConfig = ''
        pinentry-program ${pkgs.pinentry.gnome3}/bin/pinentry-gnome3
      '';
}
