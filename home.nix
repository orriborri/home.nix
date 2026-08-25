{
  pkgs,
  lib,
  config,
  pkgs-stable ? pkgs,
  ...
}:

let
  # System detection
  isSilverblue = builtins.pathExists /run/ostree-booted;
  isNixOS = builtins.pathExists /etc/NIXOS;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
{
  # Home Manager needs a bit of information about you and the
  # paths it should manage. username / homeDirectory are set per-profile
  # by the mkHome builder in flake.nix; these mkDefault values are the
  # fallback for a bare `nix run .#<user>`.
  home = {
    username = lib.mkDefault "orre";
    homeDirectory = lib.mkDefault (
      if isDarwin then "/Users/${config.home.username}" else "/home/${config.home.username}"
    );
    stateVersion = "26.05";
  };

  # Nixpkgs configuration
  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "obsidian"
          "kiro"
          "kiro-cli"
          "kiro-cli-unwrapped"
        ];
      permittedInsecurePackages = [ ];
    };
    overlays = [
    ];
  };

  # Environment variables
  home.sessionVariables = {
    BROWSER = "firefox";
    PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
  }
  // lib.optionalAttrs isLinux {
    LD_LIBRARY_PATH = lib.makeLibraryPath [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ];
  };

  # System packages
  home.packages =
    with pkgs;
    [
      # Essential tools
      gh
      fx
      tzdata

      # Fonts
      nerd-fonts.jetbrains-mono
      nerd-fonts.hack
      powerline-fonts
      font-awesome
      liberation_ttf

      # Applications
      firefox
      devbox
      amazon-q-cli
      gitlab-ci-local
      awscli2
    ]
    ++ lib.optionals isLinux [
      emote # GTK emoji picker (Linux-only)
    ]
    ++ lib.optionals isDarwin [
      # macOS-specific packages can go here
    ];

  # Programs
  programs = {
    home-manager.enable = true;

    # CLI tools (per-tool config in ./<tool>.nix)
    zsh = (import ./zsh.nix { inherit pkgs lib config; });
    starship = (import ./starship.nix { inherit pkgs; });
    direnv = (import ./direnv.nix { inherit pkgs; });
    zoxide = (import ./zoxide.nix { inherit pkgs; });
    carapace = (import ./carapace.nix { inherit pkgs; });
    atuin = (import ./atuin.nix { inherit pkgs; });
    neovim = (import ./neovim-config.nix { inherit pkgs; });
    git = (import ./git.nix { inherit pkgs lib; });
    gitui = (import ./gitui.nix { inherit pkgs; });
    lazygit = (import ./lazygit.nix { inherit pkgs; });
    lsd = (import ./lsd.nix { inherit pkgs; });
    htop = (import ./htop.nix { inherit pkgs; });
    zellij = (import ./zellij.nix { inherit pkgs; });

    # Better git diff viewer
    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        line-numbers = true;
        side-by-side = true;
        syntax-theme = "Dracula";
      };
    };

    # Fuzzy finder with shell integration
    fzf = {
      enable = true;
      enableZshIntegration = true;
      # Cede Ctrl-R to Atuin (which is sourced last and owns history search);
      # fzf keeps Ctrl-T (files) and Alt-C (cd).
      historyWidget.command = "";
      defaultCommand = "fd --type f --hidden --follow --exclude .git";
      defaultOptions = [
        "--height 40%"
        "--layout=reverse"
        "--border"
        "--inline-info"
      ];
    };

    # Better file manager
    yazi = {
      enable = true;
      enableZshIntegration = true;
      shellWrapperName = "yy";
    };

    # Better cat alternative
    bat = {
      enable = true;
      config = {
        theme = "TwoDark";
        style = "numbers,changes,header";
      };
    };
  };

  # Font configuration - make Nix-managed fonts visible to all apps (including Flatpak)
  fonts.fontconfig.enable = true;

  # XDG configuration
  xdg = {
    enable = true;
    # mimeApps is Linux-only in home-manager
    mimeApps = lib.mkIf isLinux {
      enable = true;
      defaultApplications = {
        "text/html" = "firefox.desktop";
        "x-scheme-handler/http" = "firefox.desktop";
        "x-scheme-handler/https" = "firefox.desktop";
      };
    };
  };

  # Enable generic Linux integration (XDG_DATA_DIRS, etc.) on non-NixOS
  targets.genericLinux.enable = isLinux && !isNixOS;

  # Flat modules imported directly (FruitieX-style layout).
  # Platform-/host-specific modules (kiro-ide, cosmic) are added per-profile
  # by the mkHome builder in flake.nix — keep this list static and pure.
  imports = [
    # Module-style program configs
    ./neovim.nix
    ./zellij-layout.nix
    # Features
    ./development.nix
    ./utilities.nix
    ./security.nix
    # Services
    ./gpg-agent.nix
    ./vault-sync.nix
  ];
}
