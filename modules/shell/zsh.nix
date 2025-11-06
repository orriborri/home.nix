{ pkgs, ... }:

{
  enable = true;

  autosuggestion.enable = true;
  enableVteIntegration = true;
  completionInit = "autoload -U compinit && compinit -u";

  shellAliases = {
    da = "direnv allow";
    g = "git";
    c = "code";
    ssh = "ssh";
    ssh-add = "ssh-add";
    scp = "scp";
    zed = "DISPLAY=:0 zed";
    nm = "nm-tui";  # Network manager TUI
  };

  initContent = pkgs.lib.mkOrder 1 ''
    export ZSH_DISABLE_COMPFIX=true
    eval "$(zellij setup --generate-auto-start zsh)"
    # 'jj' enters normal mode
    bindkey -M viins 'jj' vi-cmd-mode
  '';

  profileExtra = ''
    # Adds global npm & yarn packages to $PATH
    export PATH="$HOME/.npm-packages/bin:$HOME/.yarn/bin:$PATH";

    # Adds local npm & yarn packages to $PATH
    export PATH="./node_modules/.bin:$PATH"

    # Adds pip packages to $PATH
    export PATH="$HOME/.local/bin:$PATH"

    # Adds cargo packages to $PATH
    . "$HOME/.cargo/env"

  ''
  + (
    if pkgs.stdenv.isDarwin then
      ''
        eval "$(/opt/homebrew/bin/brew shellenv)"
      ''
    else
      ''
        # export DISPLAY=$(grep -m 1 nameserver /etc/resolv.conf | awk '{print $2}'):0
      ''
  );

  sessionVariables = {
    # Suppress direnv logs
    DIRENV_LOG_format = "";

    # Don't use nano
    EDITOR = "vim";

    # 'jj' enters normal mode
    ZVM_VI_INSERT_ESCAPE_BINDKEY = "jj";

    # NPM global packages
    NPM_CONFIG_PREFIX = "$HOME/.npm-packages";
  };

  plugins = [
    {
      name = "fast-syntax-highlighting";
      src = "${pkgs.zsh-fast-syntax-highlighting}/share/zsh/site-functions";
    }
    # {
    #   name = "zsh-vi-mode";
    #   src = builtins.fetchGit {
    #     url = "https://github.com/jeffreytse/zsh-vi-mode";
    #     rev = "9178e6bea2c8b4f7e998e59ef755820e761610c7";
    #   };
    # }
  ];
}
