{ pkgs, lib, config, pkgs-stable ? pkgs, ... }:

let
  # Configuration variables
  username = "orre";
  homeDirectory = "/home/${username}";

  # System detection
  isNixOS = builtins.pathExists /etc/NIXOS;
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;
in
{
  home = {
    inherit username homeDirectory;
    stateVersion = "26.05";
  };

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "obsidian"
      ];
      permittedInsecurePackages = [ ];
    };
    overlays = [ ];
  };

  home.sessionVariables = {
    BROWSER = "firefox";
  };

  home.packages = with pkgs; [
    # Essential tools
    gh

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
  ];

  programs = {
    home-manager.enable = true;
  };

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

  # Enable generic Linux integration (XDG_DATA_DIRS, etc.) on non-NixOS
  targets.genericLinux.enable = isLinux && !isNixOS;

  # Cosmic Atomic: CLI apps, features, services, and Cosmic desktop module
  imports = [
    ./modules/applications
    ./modules/feature
    ./modules/service
    ./modules/desktop/cosmic.nix
    ./packages/kiro.nix
  ];
}
