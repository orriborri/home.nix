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
    stateVersion = "25.05";
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
    ];
  };

  # Environment variables
  home.sessionVariables = {
    BROWSER = "firefox";
  } // lib.optionalAttrs isLinux {
    LD_LIBRARY_PATH = "${lib.makeLibraryPath (with pkgs; [
      mesa
      libglvnd
      libGL
      libGLU
    ])}:$LD_LIBRARY_PATH";
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
    libglvnd
    libGL
    libGLU
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


  # Import modules
  imports = [
    ./modules/applications
    ./modules/feature
    ./modules/service
    # ./packages/kiro.nix
  ] ++ lib.optionals (windowManager == "sway") [
    ./modules/desktop/windowManager/sway
  ];
}
