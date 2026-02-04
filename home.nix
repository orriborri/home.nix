{ pkgs, lib, config, pkgs-stable ? pkgs, ... }:

let
  # Configuration variables
  username = "orre";
  homeDirectory = "/home/${username}";
  windowManager = "sway"; # Using Sway as the window manager

  # System detection
  isNixOS = builtins.pathExists /etc/NIXOS;
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;
in
{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home = {
    inherit username homeDirectory;
    stateVersion = "24.05";
  };

  # Nixpkgs configuration
  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "obsidian"
      ];
      permittedInsecurePackages = [];
    };
    overlays = [
      (final: prev: {
        nodejs = prev.nodejs_latest;
      })
    ];
  };

  # Environment variables
  home.sessionVariables = {
    BROWSER = "firefox";
  };

  # System packages
  home.packages = with pkgs; [
    # Essential tools
    gh
    power-profiles-daemon

    # Fonts
    nerd-fonts.jetbrains-mono
    nerd-fonts.hack
    powerline-fonts
    font-awesome
    liberation_ttf

    # Applications
    emote
    devbox
    amazon-q-cli
    gitlab-ci-local
    awscli2
    # Graphics and Wayland support (Linux only)
  ] ++ lib.optionals isLinux [
    mesa
    vulkan-loader
    vulkan-headers
    vulkan-tools
    libva
    libva-utils
  ] ++ lib.optionals isDarwin [
    # macOS-specific packages can go here
  ];

  # Programs
  programs = {
    home-manager.enable = true;

    # Better directory navigation
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };


    # Fuzzy finder with shell integration
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };

  # XDG configuration
  xdg = {
    enable = true;
    mimeApps = {
      enable = true;
      defaultApplications = {
        "text/html" = "org.mozilla.firefox.desktop";
        "x-scheme-handler/http" = "org.mozilla.firefox.desktop";
        "x-scheme-handler/https" = "org.mozilla.firefox.desktop";
      };
    };
  };

  # Security and GPG
  programs.gpg.enable = true;
  services.gpg-agent = lib.mkIf isLinux {
    enable = true;
    pinentry.package = pkgs.pinentry-gtk2;
  };

  # Import modules gradually for testing
  imports = [
    ./modules/shell
    ./modules/development
    ./modules/utilities.nix
    ./packages/kiro.nix
  ] ++ lib.optionals (windowManager == "sway") [
    ./modules/wm/sway
  ];
}
