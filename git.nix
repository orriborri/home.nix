{ pkgs, ... }:

let
  # post-checkout hook (configured below, so it runs alongside husky's
  # hooksPath): on `git worktree add` (previous HEAD is the null sha), give the
  # new worktree a copy-on-write (reflink) copy of every node_modules in the
  # main checkout (**/node_modules, outermost only, skipping other worktrees
  # nested inside it). Workspace links inside node_modules are relative, so
  # they resolve to the new worktree's own packages. Never fails the checkout.
  nodeModulesCow = pkgs.writeShellApplication {
    name = "git-node-modules-cow";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.gawk
      pkgs.findutils
    ];
    text = ''
      [ "''${1:-}" = 0000000000000000000000000000000000000000 ] || exit 0

      new=$(git rev-parse --show-toplevel)
      mapfile -t trees < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
      main=''${trees[0]}
      [ "$new" != "$main" ] || exit 0

      skip=(-name .git)
      for t in "''${trees[@]:1}"; do skip+=(-o -path "$t"); done

      copied=0
      while IFS= read -r -d "" src; do
        rel=''${src#"$main"/}
        dst="$new/$rel"
        # Only where this branch has the package and no node_modules yet.
        if [ ! -d "$(dirname "$dst")" ] || [ -e "$dst" ]; then continue; fi
        if ! cp -a --reflink=always "$src" "$dst" 2>/dev/null; then
          rm -rf "$dst"
          echo "node_modules: reflink not supported here, skipped" >&2
          exit 0
        fi
        copied=$((copied + 1))
      done < <(find "$main" \( "''${skip[@]}" \) -prune -o -type d -name node_modules -prune -print0)

      [ "$copied" -gt 0 ] || exit 0
      pm=npm
      [ -e "$new/pnpm-lock.yaml" ] && pm=pnpm
      echo "node_modules: reflinked $copied dirs from $main. Next: $pm install"
    '';
  };
in
{
  enable = true;

  # Manage git-lfs declaratively. This writes the filter.lfs.* config into
  # the Home Manager-managed gitconfig, so `git lfs install` is unnecessary
  # (and would fail anyway, since ~/.config/git/config is a read-only symlink
  # into the Nix store).
  lfs.enable = true;

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
      # The Home Manager SSH package already forces ~/.ssh/config, avoiding
      # Fedora's incompatible system crypto-policy for every SSH consumer.
      sshCommand = "ssh";
    };

    merge = {
      conflictstyle = "diff3";
      tool = "vimdiff";
    };

    pull = {
      rebase = true;
      ff = "only";
    };

    # Refresh code-review-graph after a pull (ff -> post-merge, rebase ->
    # post-rewrite). Config hooks run alongside a repo's own hooks. Only repos
    # that already have a graph; backgrounded so the pull returns at once.
    hook.crg-update = {
      event = [
        "post-merge"
        "post-rewrite"
      ];
      command = ''top=$(git rev-parse --show-toplevel) && [ -d "$top/.code-review-graph" ] && command -v code-review-graph >/dev/null && { nohup code-review-graph update --skip-flows --repo "$top" --quiet >/dev/null 2>&1 & }; true'';
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

    hook.node-modules-cow = {
      event = "post-checkout";
      command = "${nodeModulesCow}/bin/git-node-modules-cow";
    };

    # Push over SSH, fetch public repos over HTTPS. Only the private readpeak
    # group is fetched over SSH too, since HTTPS would prompt for credentials.
    url = {
      "git@github.com:" = {
        pushInsteadOf = "https://github.com/";
      };
      "git@gitlab.com:" = {
        pushInsteadOf = "https://gitlab.com/";
      };
      "git@gitlab.com:readpeak/" = {
        insteadOf = "https://gitlab.com/readpeak/";
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

      cleanup = "!git branch --merged | grep -v '\\*\\|main\\|master\\|develop' | xargs -n 1 git branch -d";
      prune-all = "!git remote | xargs -n 1 git remote prune";
    };
  };
}
