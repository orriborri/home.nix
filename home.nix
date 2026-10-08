{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Platform detection only. Host facts like "is this NixOS" cannot be read
  # from the filesystem: pure flake eval makes builtins.pathExists on host
  # paths always false. Set those per profile in flake.nix instead.
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
      permittedInsecurePackages = [ ];
    };
    overlays = [
    ];
  };

  # Weekly user-profile GC on the laptop. Generations are cheap (199M for 17
  # old ones on 2026-10-08); the timer mainly sweeps paths left behind by
  # deleted .direnv roots and `nix build` results. EC2 has its own nix.gc.
  nix.gc = lib.mkIf (isLinux && config.kirocrew.role == "workstation") {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
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

  # Login-independent PATH additions. Written into the session environment
  # (hm-session-vars.sh + imported into the systemd user environment), so
  # non-interactive contexts such as AI coding-agent hooks resolve these too,
  # not only interactive zsh. ~/.local/bin holds curl-installed tools (aidlc,
  # kirocrew, code-review-graph) that AI-DLC's hooks must find.
  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  # GUI apps launched by GNOME get PATH from the systemd user environment,
  # not the shell, so desktop entries with a bare Exec (claude-desktop) need
  # the Nix profile there.
  systemd.user.sessionVariables = lib.optionalAttrs isLinux {
    PATH = "${config.home.profileDirectory}/bin:$HOME/.local/bin:$PATH";
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
    zsh = import ./zsh.nix { inherit pkgs lib config; };
    starship = import ./starship.nix { inherit pkgs; };
    direnv = import ./direnv.nix { inherit pkgs; };
    zoxide = import ./zoxide.nix { inherit pkgs; };
    carapace = import ./carapace.nix { inherit pkgs; };
    atuin = import ./atuin.nix { inherit pkgs; };
    git = import ./git.nix { inherit pkgs lib; };
    gitui = import ./gitui.nix { inherit pkgs; };
    lazygit = import ./lazygit.nix { inherit pkgs; };
    lsd = import ./lsd.nix { inherit pkgs; };
    zellij = import ./zellij.nix { inherit pkgs; };

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
        # Claude Desktop can't register itself: mimeapps.list is read-only.
        "x-scheme-handler/claude" = "com.anthropic.Claude.desktop";
      };
    };
  };

  # Enable generic Linux integration (XDG_DATA_DIRS, etc.) on non-NixOS.
  # NixOS profiles override this to false (flake.nix kirocrewModules).
  targets.genericLinux.enable = lib.mkDefault isLinux;

  # Flat modules imported directly (FruitieX-style layout).
  # Platform-/host-specific modules (kiro-ide, cosmic) are added per-profile
  # by the mkHome builder in flake.nix — keep this list static and pure.
  imports = [
    # Module-style program configs
    ./neovim.nix
    ./zellij-layout.nix
    # Features
    ./development.nix
    ./git-worktree-prune.nix
    ./utilities.nix
    ./security.nix
    ./aidlc.nix
    # KiroCrew declarative config (options + repos.toml + known_hosts)
    ./kirocrew-config.nix
    # Services
    ./gpg-agent.nix
  ];
}
