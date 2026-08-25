{
  pkgs,
  lib,
  pkgs-stable ? pkgs,
  ...
}:

{
  # Development packages organized by category
  home.packages = with pkgs; [
    # Programming languages
    nodejs_latest
    pnpm
    python3 # Python interpreter
    pipx # Install Python apps in isolated environments

    # Development tools
    curl # HTTP client (CLI)
    openssl # TLS/SSL toolkit
    tokei # Code statistics
    jq # JSON processor
    xh # HTTP client
    pre-commit # Git hooks
    lazyworktree # Git worktree TUI
    glab # GitLab CLI
    uv # Python package manager

    # Nix development tools
    nix # Nix CLI (nix-shell, nix-build, nix develop, etc.)
    nil # Nix LSP
    nixd # Alternative Nix LSP
    nixfmt # Nix formatter (updated from nixfmt-rfc-style)

    # Shell utilities
    zsh

    # AI coding tools

    # AWS tools
    ssm-session-manager-plugin # SSM tunnel for kirocrew EC2 instance
  ];

  # Development environment variables
  home.sessionVariables = {
    # Development paths
    EDITOR = "nvim";

    # Node.js configuration
    NPM_CONFIG_PREFIX = "$HOME/.npm-packages";

    # Python configuration
    PYTHONPATH = "$HOME/.local/lib/python3.11/site-packages:$PYTHONPATH";
  };

  # Install Python tools via uv (isolated venvs, managed by Home Manager activation)
  home.activation.uvTools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="${pkgs.uv}/bin:${pkgs.python3}/bin:$PATH"
    ${pkgs.uv}/bin/uv tool install --force code-review-graph 2>/dev/null || true
  '';

  # Clone repos declared in config/repos.toml (idempotent -- skips existing)
  # Reads from the XDG path placed by kirocrew-config.nix.
  # Respects KIROCREW_ROLE for per-host filtering and 'shallow' for clone depth.
  home.activation.cloneRepos = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        MANIFEST="$HOME/.config/kirocrew/repos.toml"
        # Fallback to old path during transition
        if [ ! -f "$MANIFEST" ]; then
          MANIFEST="$HOME/.config/home-manager/config/repos.toml"
        fi
        if [ -f "$MANIFEST" ]; then
          ${pkgs.python3}/bin/python3 -c "
    import tomllib, os, subprocess, sys
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
    home = os.path.expanduser('~')
    role = os.environ.get('KIROCREW_ROLE', 'workstation')
    for repo in data.get('repos', []):
        targets = repo.get('targets', ['workstation', 'headless'])
        if role not in targets:
            continue
        target = os.path.join(home, repo['path'])
        if not os.path.isdir(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shallow = repo.get('shallow', True)
            cmd = ['git', 'clone']
            if shallow:
                cmd += ['--depth=1']
            cmd += [repo['remote'], target]
            print(f'Cloning {repo[\"remote\"]} -> {target}')
            subprocess.run(cmd, capture_output=True)
    " "$MANIFEST"
        fi
  '';

  # Auto-register git repos from the manifest with code-review-graph
  home.activation.crgRegisterRepos = lib.hm.dag.entryAfter [ "cloneRepos" "uvTools" ] ''
        CRG="$HOME/.local/bin/code-review-graph"
        MANIFEST="$HOME/.config/kirocrew/repos.toml"
        if [ ! -f "$MANIFEST" ]; then
          MANIFEST="$HOME/.config/home-manager/config/repos.toml"
        fi
        if [ -x "$CRG" ] && [ -f "$MANIFEST" ]; then
          ${pkgs.python3}/bin/python3 -c "
    import tomllib, os, subprocess, sys
    with open(sys.argv[1], 'rb') as f:
        repos = tomllib.load(f).get('repos', [])
    home = os.path.expanduser('~')
    crg = sys.argv[2]
    role = os.environ.get('KIROCREW_ROLE', 'workstation')
    for repo in repos:
        targets = repo.get('targets', ['workstation', 'headless'])
        if role not in targets:
            continue
        target = os.path.join(home, repo['path'])
        if os.path.isdir(os.path.join(target, '.git')):
            subprocess.run([crg, 'register', target], capture_output=True)
    " "$MANIFEST" "$CRG"
        fi
  '';

  # code-review-graph daemon: auto-updates graphs for all registered repos
  systemd.user.services.crg-daemon = {
    Unit = {
      Description = "code-review-graph watch daemon";
      After = [ "default.target" ];
    };
    Service = {
      ExecStart = "%h/.local/bin/crg-daemon start --foreground";
      Restart = "on-failure";
      RestartSec = "10";
      Environment = "PATH=%h/.local/bin:%h/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
