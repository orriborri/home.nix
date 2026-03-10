{ ... }:

{
  enable = true;

  ignores = [
    "target"
    "build"
    "dist"
    "*.o"
    "*.so"
    "*.dylib"
    ".vscode"
    ".idea"
    ".direnv"
    ".envrc"
    "*~"
    "*.swp"
    "*.swo"
    ".DS_Store"
    ".env"
    ".env.local"
    "*.log"
    "logs"
    "node_modules"
    ".pnp"
    ".pnp.js"
    "Thumbs.db"
    "ehthumbs.db"
    "Desktop.ini"
  ];

  settings = {
    user = {
      email = "oscar.henriksson91@gmail.com";
      name = "Oscar Henriksson";
      signingkey = "";
    };

    commit = {
      gpgsign = false;
    };

    tag = {
      gpgsign = false;
    };

    push = {
      default = "simple";
      autoSetupRemote = true;
      followTags = true;
    };

    core = {
      autocrlf = "input";
      eol = "lf";
      editor = "nvim";
      whitespace = "trailing-space,space-before-tab";
    };

    merge = {
      conflictstyle = "diff3";
      tool = "vimdiff";
    };

    pull = {
      rebase = true;
      ff = "only";
    };

    diff = {
      compactionHeuristic = true;
      algorithm = "patience";
      colorMoved = "default";
    };

    rebase = {
      autoStash = true;
      autoSquash = true;
    };

    branch = {
      autosetupmerge = "always";
      autosetuprebase = "always";
    };

    init = {
      defaultBranch = "main";
    };

    fetch = {
      prune = true;
      pruneTags = true;
    };

    status = {
      showUntrackedFiles = "all";
      submoduleSummary = true;
    };

    log = {
      date = "iso";
      decorate = "short";
    };

    url = {
      "git@github.com:" = {
        insteadOf = "https://github.com/";
      };
      "git@gitlab.com:" = {
        insteadOf = "https://gitlab.com/";
      };
    };

    alias = {
      main = "!git symbolic-ref refs/remotes/origin/HEAD | cut -d'/' -f4";
      remotesh = "remote set-head origin --auto";

      a = "add";
      ap = "add --patch";
      aa = "add --all";

      b = "branch";
      bc = "checkout -b";
      bd = "branch --delete";
      bD = "branch --delete --force";

      c = "commit --verbose";
      ca = "commit --verbose --all";
      cam = "commit --all --message";
      cm = "commit --message";
      co = "checkout";
      com = "! git checkout $(git main)";
      cf = "commit --amend --reuse-message HEAD";
      cfa = "commit --amend --all --reuse-message HEAD";
      cp = "cherry-pick --ff";

      d = "diff";
      dc = "diff --cached";
      dom = "! git diff origin/$(git main)";
      dt = "difftool";

      f = "fetch";
      fa = "fetch --all";
      cl = "clone";
      clr = "clone --recursive";
      pl = "pull";
      pla = "pull --all";

      ir = "reset";
      irh = "reset --hard";
      irs = "reset --soft";
      irs1 = "reset --soft HEAD~1";

      lg = "!git log --topo-order --all --graph --pretty=format:\"%C(green)%h%C(reset) %s%C(red)%d%C(reset)%n\"";
      lga = "log --topo-order --all --graph --pretty=format:'%C(green)%h%C(reset) %C(blue)%an%C(reset) %s%C(red)%d%C(reset)%n'";
      lol = "log --graph --decorate --pretty=oneline --abbrev-commit";
      lola = "log --graph --decorate --pretty=oneline --abbrev-commit --all";

      p = "push";
      pc = "!git push --set-upstream origin $(git rev-parse --abbrev-ref HEAD)";
      pf = "push --force-with-lease";
      pt = "push --tags";

      r = "rebase";
      ra = "rebase --abort";
      rc = "rebase --continue";
      from = "! git fetch && git rebase origin/$(git main)";
      rom = "! git rebase origin/$(git main)";
      ri = "rebase --interactive";
      riom = "! git rebase --interactive origin/$(git main)";
      rs = "rebase --skip";

      s = "stash";
      sa = "stash apply";
      sd = "stash show --patch";
      sl = "stash list";
      sp = "stash pop";
      ss = "stash save";

      sh = "show";
      shs = "show --stat";

      st = "status --short --branch";

      sw = "switch";
      swc = "switch --create";

      wt = "worktree";
      wta = "worktree add";
      wtl = "worktree list";
      wtr = "worktree remove";

      aliases = "config --get-regexp alias";
      unstage = "reset HEAD --";
      last = "log -1 HEAD";
      visual = "!gitk";

      cleanup = "!git branch --merged | grep -v '\\*\\|main\\|master\\|develop' | xargs -n 1 git branch -d";
      prune-all = "!git remote | xargs -n 1 git remote prune";
    };
  };
}
