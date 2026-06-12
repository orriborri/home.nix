{ pkgs, lib, config, ... }:

{
  # Shell configuration
  enable = true;
  
  # Use XDG config directory for zsh files (resolves deprecation warning)
  dotDir = "${config.xdg.configHome}/zsh";

  # Shell options
  autosuggestion.enable = true;
  enableVteIntegration = true;
  completionInit = "autoload -U compinit && compinit -u";
  
  # History configuration
  history = {
    size = 10000;
    save = 10000;
    extended = true;
    ignoreDups = true;
    ignoreSpace = true;
  };

  # Shell aliases organized by category
  shellAliases = {
    # Directory navigation
    da = "direnv allow";
    
    # Git shortcuts
    g = "git";
    lgit = "lazygit";
    
    # Editor shortcuts
    c = "code";
    k = "kiro-ide";
    v = "nvim";
    
    # Network utilities
    ssh = "ssh";
    ssh-add = "ssh-add";
    scp = "scp";
    nm = "nm-tui";
    
    # Application shortcuts
    zed = "DISPLAY=:0 zed";
    
    # Worktree navigation
    lw = "lazyworktree --output-selection /tmp/lwt_path </dev/tty >/dev/tty && cd \"$(cat /tmp/lwt_path)\"";

    # TMC CLI
    tmc = "/home/orre/Courses/Security/SecuringSoftware/tmc-cli-rust-x86_64-unknown-linux-gnu-v1.1.2";

    # Nix utilities
    hm = "home-manager";
    hms = "home-manager switch";
    hmb = "home-manager build";

    # Help
    help = "echo '── Zsh Vi Mode ──\njj    → normal mode\ni     → insert mode\nv     → visual mode\n/     → search\nCtrl-R → history search\nCtrl-S → forward search\n── Navigation ──\n0/\\$   → line start/end\nw/b   → word forward/back\nf<c>  → jump to char\n── Editing ──\ndd    → delete line\ncc    → change line\nyy    → yank line\np     → paste\nu     → undo\n'";
  };

  # Shell initialization
  initContent = lib.mkOrder 1000 ''
    export ZSH_DISABLE_COMPFIX=true
    
    # AWS CLI completion (after compinit)
    autoload -Uz bashcompinit && bashcompinit
    complete -C '${pkgs.awscli2}/bin/aws_completer' aws
    
    # Zellij auto-start
    if [[ -z "$ZELLIJ" && -z "$ZELLIJ_STARTING" ]]; then
      export ZELLIJ_STARTING=1
      zellij attach --create main 2>/dev/null
      unset ZELLIJ_STARTING
    fi

    # Vi mode keybindings
    bindkey -M viins 'jj' vi-cmd-mode
    
    # Bracketed paste (prevents keybindings triggering during paste)
    autoload -Uz bracketed-paste-magic
    zle -N bracketed-paste bracketed-paste-magic
    
    # Better history search
    bindkey '^R' history-incremental-search-backward
    bindkey '^S' history-incremental-search-forward
    
    # Directory navigation
    setopt AUTO_CD
    setopt AUTO_PUSHD
    setopt PUSHD_IGNORE_DUPS
    
    # Multiline command support
    setopt INTERACTIVE_COMMENTS
    setopt PROMPT_SUBST
    export PS2="%F{yellow}∙%f "
    
    # Completion improvements
    setopt COMPLETE_ALIASES
    setopt GLOB_COMPLETE
    
    # History options
    setopt HIST_VERIFY
    setopt SHARE_HISTORY
    setopt APPEND_HISTORY
  '';

  # Environment for every zsh (interactive or not). hm-session-vars.sh has a
  # source-once guard (__HM_SESS_VARS_SOURCED) that can leak into the desktop
  # session while Fedora rebuilds PATH without the nix entries — so ensure the
  # nix profile paths are always present, independent of that guard.
  envExtra = ''
    case ":$PATH:" in
      *":$HOME/.nix-profile/bin:"*) ;;
      *) export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH" ;;
    esac
  '';

  # Profile configuration
  profileExtra = ''
    # Development paths
    export PATH="$HOME/.npm-packages/bin:$HOME/.yarn/bin:$PATH"
    export PATH="./node_modules/.bin:$PATH"
    export PATH="$HOME/.local/bin:$PATH"
    export PATH="$HOME/.cargo/bin:$PATH"

    # Load cargo environment if available
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  ''
  + lib.optionalString pkgs.stdenv.isDarwin ''
    # macOS specific
    eval "$(/opt/homebrew/bin/brew shellenv)"
  '';

  # Session variables
  sessionVariables = {
    # TMC configuration
    TMC_LANGS_CONFIG_DIR = "/home/orre/tmc-config";

    # Suppress direnv logs
    DIRENV_LOG_FORMAT = "";

    # Editor preference
    EDITOR = "nvim";
    VISUAL = "nvim";

    # Vi mode configuration
    ZVM_VI_INSERT_ESCAPE_BINDKEY = "jj";

    # NPM global packages
    NPM_CONFIG_PREFIX = "$HOME/.npm-packages";
    
    # Better less defaults
    LESS = "-R -S -M -I -x4";
    
    # FZF configuration
    FZF_DEFAULT_OPTS = "--height 40% --layout=reverse --border --inline-info";
  };

  # Plugins
  plugins = [
    {
      name = "fast-syntax-highlighting";
      src = "${pkgs.zsh-fast-syntax-highlighting}/share/zsh/site-functions";
    }
    {
      name = "zsh-autosuggestions";
      src = "${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions";
    }
  ];
}
