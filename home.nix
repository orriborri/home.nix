{ config, pkgs, ... }:

{
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "orre";
  home.homeDirectory = "/home/orre";
  nixpkgs.config.allowUnfree = true;
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
  home.stateVersion = "21.05";
  home.packages = with pkgs; [
    (uutils-coreutils.override { prefix = ""; })
    less # Non busybox version of less needed by delta

    ripgrep
    igrep

    fd
    skim

    jq
    unzip
    ncdu
    strace
    # binutils
    # binutils
    tokei
    xh
    jc
    xclip
    bottom
    jless
    navi
    tealdeer
    fend

    zellij

    dust
    dua

    gitAndTools.gh

    nodejs
    nodePackages.pnpm
    cargo
    rustc
    pre-commit
    lsd
    zoxide
    pueue
    devbox
    nixfmt-rfc-style
    uv
    
    zed # Modern, high-performance code editor

  ];

  home.activation.installNvm = config.lib.dag.entryAfter [ "checkLinkTargets" ] ''
    if [ ! -d "$HOME/.nvm" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
    fi
  '';

  programs = {
    neovim = (import ./neovim.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs; });
    tmux = (import ./tmux.nix { inherit pkgs; });
    zsh = (import ./zsh.nix { inherit pkgs; });
    starship = (import ./starship.nix { inherit pkgs; });
    direnv = (import ./direnv.nix { inherit pkgs; });
    eza = (import ./eza.nix { inherit pkgs; });
    htop = (import ./htop.nix { inherit pkgs; });
    nushell = (import ./nushell.nix { inherit pkgs; });
    zoxide = (import ./zoxide.nix { inherit pkgs; });
    carapace = (import ./carapace.nix { inherit pkgs; });
    atuin = (import ./atuin.nix { inherit pkgs; });
    gitui = (import ./gitui.nix { inherit pkgs; });
  };


}
