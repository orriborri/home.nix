{ pkgs, lib, ... }:

{
  enable = true;

  # Global gitignore
  ignores = [
    # Build artifacts
    "target"
    "build"
    "dist"
    "*.o"
    "*.so"
    "*.dylib"
    
    # IDE and editor files
    ".vscode"
    ".idea"
    "*.swp"
    "*.swo"
    "*~"
    ".DS_Store"
    
    # Environment and secrets
    ".env"
    ".env.local"
    ".direnv"
    
    # Logs
    "*.log"
    "logs"
    
    # Dependencies
    "node_modules"
    ".pnp"
    ".pnp.js"
    
    # OS generated files
    "Thumbs.db"
    "ehthumbs.db"
    "Desktop.ini"
  ];

  # Git configuration using new settings format
  settings = {
    # User settings
    user = {
      name = "Oscar Henriksson";
      email = "oscar.henriksson91@gmail.com";
      signingkey = ""; # Add your GPG key ID here
    };

    # Security settings
    commit = {
      gpgsign = false; # Set to true when GPG key is configured
    };
    
    tag = {
      gpgsign = false; # Set to true when GPG key is configured
    };

    # Core settings
    core = {
      autocrlf = "input";
      eol = "lf";
      editor = "nvim";
      # pager will be set by delta integration
      whitespace = "trailing-space,space-before-tab";
    };

    # Push settings
    push = {
      default = "simple";
      autoSetupRemote = true;
      followTags = true;
    };

    # Pull settings
    pull = {
      rebase = true;
      ff = "only";
    };

    # Merge settings
    merge = {
      conflictstyle = "diff3";
      tool = "vimdiff";
    };

    # Rebase settings
    rebase = {
      autoStash = true;
      autoSquash = true;
    };

    # Diff settings
    diff = {
      compactionHeuristic = true;
      algorithm = "patience";
      colorMoved = "default";
    };

    # Branch settings
    branch = {
      autosetupmerge = "always";
      autosetuprebase = "always";
    };

    # Init settings
    init = {
      defaultBranch = "main";
    };

    # Fetch settings
    fetch = {
      prune = true;
      pruneTags = true;
    };

    # Status settings
    status = {
      showUntrackedFiles = "all";
      submoduleSummary = true;
    };

    # Log settings
    log = {
      date = "iso";
      decorate = "short";
    };

    # URL rewrites for security (use SSH instead of HTTPS)
    url = {
      "git@github.com:" = {
        insteadOf = "https://github.com/";
      };
      "git@gitlab.com:" = {
        insteadOf = "https://gitlab.com/";
      };
    };

    # Git aliases using new format
    alias = {
      # Branch management
      main = "!git symbolic-ref refs/remotes/origin/HEAD | cut -d'/' -f4";
      remotesh = "remote set-head origin --auto";
      b = "branch";
      bc = "checkout -b";
      bd = "branch --delete";
      bD = "branch --delete --force";
      
      # Staging and committing
      a = "add";
      ap = "add --patch";
      aa = "add --all";
      c = "commit --verbose";
      ca = "commit --verbose --all";
      cam = "commit --all --message";
      cm = "commit --message";
      cf = "commit --amend --reuse-message HEAD";
      cfa = "commit --amend --all --reuse-message HEAD";
      
      # Checkout and switching
      co = "checkout";
      com = "!git checkout $(git main)";
      sw = "switch";
      swc = "switch --create";
      
      # Diffing
      d = "diff";
      dc = "diff --cached";
      dom = "!git diff origin/$(git main)";
      dt = "difftool";
      
      # Fetching and pulling
      f = "fetch";
      fa = "fetch --all";
      pl = "pull";
      pla = "pull --all";
      
      # Cloning
      cl = "clone";
      clr = "clone --recursive";
      
      # Resetting
      ir = "reset";
      irh = "reset --hard";
      irs = "reset --soft";
      irs1 = "reset --soft HEAD~1";
      
      # Logging
      lg = "log --topo-order --all --graph --pretty=format:'%C(green)%h%C(reset) %s%C(red)%d%C(reset)%n'";
      lga = "log --topo-order --all --graph --pretty=format:'%C(green)%h%C(reset) %C(blue)%an%C(reset) %s%C(red)%d%C(reset)%n'";
      lol = "log --graph --decorate --pretty=oneline --abbrev-commit";
      lola = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
    
      # Pushing
      p = "push";
      pc = "!git push --set-upstream origin $(git rev-parse --abbrev-ref HEAD)";
      pf = "push --force-with-lease";
      pt = "push --tags";
      
      # Rebasing
      r = "rebase";
      ra = "rebase --abort";
      rc = "rebase --continue";
      ri = "rebase --interactive";
      riom = "!git rebase --interactive origin/$(git main)";
      rom = "!git rebase origin/$(git main)";
      from = "!git fetch && git rebase origin/$(git main)";
      rs = "rebase --skip";
      
      # Stashing
      s = "stash";
      sa = "stash apply";
      sd = "stash show --patch";
      sl = "stash list";
      sp = "stash pop";
      ss = "stash save";
      
      # Status and showing
      st = "status --short --branch";
      sh = "show";
      shs = "show --stat";
      
      # Worktree management
      wt = "worktree";
      wta = "worktree add";
      wtl = "worktree list";
      wtr = "worktree remove";
      
      # Utilities
      aliases = "config --get-regexp alias";
      unstage = "reset HEAD --";
      last = "log -1 HEAD";
      visual = "!gitk";
      
      # Cleanup
      cleanup = "!git branch --merged | grep -v '\\*\\|main\\|master\\|develop' | xargs -n 1 git branch -d";
      prune-all = "!git remote | xargs -n 1 git remote prune";
    };
  };
}