{
  pkgs,
  config,
  lib,
  ...
}:

# Home-manager module: KiroCrew gateway as a systemd user service.
# Requires lingering enabled (users.users.orre.linger = true in NixOS config)
# on headless boxes; on desktop systems it starts with the graphical session.
#
# On EC2/headless hosts, this user service is DISABLED because the gateway
# runs as a system service under the dedicated kirocrew user instead
# (see nixos/kirocrew-services.nix). This module remains active only on
# workstation profiles where everything runs under the operator user.
#
# Sandbox is set to strict: KiroCrew's namespace-based isolation prevents
# agents from accessing operator credentials, IMDS, and system resources.
let
  cfg = config.kirocrew;
  # Detect whether sops-nix has the git-ssh-key secret declared.
  # The module is imported on all outputs but only activates where a key exists.
  hasSops = (config.sops.secrets or { }) ? "git-ssh-key";
  useSourceInstall = cfg.enable && cfg.role == "headless";
  pinnedSourceTag = if cfg.sourceTag == null then "" else cfg.sourceTag;
  kirocrewSourceRoot = "${config.home.homeDirectory}/.local/share/kirocrew-source";
  kirocrewTzdataVersion = "2026.3";
  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];
  kirocrewSourceUpdate = pkgs.writeShellApplication {
    name = "kirocrew-source-update";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.gnumake
      pkgs.gnused
      pkgs.nodejs_22
      pkgs.python313
      pkgs.stdenv.cc
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      sourceRoot=${lib.escapeShellArg kirocrewSourceRoot}
      repository="$sourceRoot/repository"
      releases="$sourceRoot/releases"
      current="$sourceRoot/current"
      pinnedTag=${lib.escapeShellArg pinnedSourceTag}
      restartMode="''${1-}"
      updated=0

      # This is a public, read-only checkout. Ignore the user's Git URL
      # rewrites so an HTTPS clone cannot be changed into an SSH clone that
      # unexpectedly requires forge credentials.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0

      mkdir -p "$sourceRoot" "$releases" "$HOME/.local/bin"
      exec 9>"$sourceRoot/update.lock"
      flock 9

      if [ ! -d "$repository/.git" ]; then
        git clone --filter=blob:none --no-checkout \
          https://github.com/kirodotdev/KiroCrew.git "$repository"
      fi

      if ! git -C "$repository" fetch --prune --tags origin; then
        if [ -x "$current/.venv/bin/kirocrew" ]; then
          echo "warning: could not refresh KiroCrew tags; keeping the current release" >&2
          exit 0
        fi
        echo "error: could not fetch KiroCrew and no installed source release exists" >&2
        exit 1
      fi

      latestStableTag="$(
        git -C "$repository" tag --list 'v[0-9]*' --sort=-version:refname \
          | sed -nE '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { p; q; }'
      )"

      if [ -n "$pinnedTag" ]; then
        selectedTag="$pinnedTag"
        if ! git -C "$repository" rev-parse --verify "refs/tags/$selectedTag^{commit}" >/dev/null; then
          echo "error: configured KiroCrew source tag $selectedTag does not exist" >&2
          exit 1
        fi
        if [ -n "$latestStableTag" ] && [ "$latestStableTag" != "$selectedTag" ]; then
          echo "KiroCrew update available: $latestStableTag (pinned to $selectedTag)"
        fi
      else
        selectedTag="$latestStableTag"
        if [ -z "$selectedTag" ]; then
          if [ -x "$current/.venv/bin/kirocrew" ]; then
            echo "warning: no stable KiroCrew tag found; keeping the current release" >&2
            exit 0
          fi
          echo "error: no stable KiroCrew release tag found" >&2
          exit 1
        fi
      fi

      release="$releases/$selectedTag"
      if [ ! -d "$release" ]; then
        git -C "$repository" worktree add --detach "$release" "$selectedTag"
      fi

      if [ ! -x "$release/.venv/bin/kirocrew" ]; then
        mkdir -p "$sourceRoot/build-state"
        KIROCREW_HOME="$sourceRoot/build-state" \
          make -C "$release" build PY=${pkgs.python313}/bin/python3
        "$release/.venv/bin/python" -m pip install "tzdata==${kirocrewTzdataVersion}"
        "$release/.venv/bin/kirocrew" --version
        updated=1
      fi

      currentTarget="$(readlink "$current" 2>/dev/null || true)"
      if [ "$currentTarget" != "$release" ]; then
        ln -sfnT "$release" "$sourceRoot/current.next"
        mv -Tf "$sourceRoot/current.next" "$current"
        updated=1
      fi

      cliLink="$HOME/.local/bin/kirocrew"
      if [ -e "$cliLink" ] && [ ! -L "$cliLink" ]; then
        echo "error: refusing to replace non-symlink $cliLink" >&2
        exit 1
      fi
      ln -sfnT "$current/.venv/bin/kirocrew" "$cliLink"

      echo "KiroCrew source release: $selectedTag"
      if [ "$restartMode" = "--restart" ] && [ "$updated" -eq 1 ]; then
        systemctl --user --no-block try-restart kirocrew.service
      fi
    '';
  };
  kirocrewExecutable =
    if useSourceInstall then
      "${kirocrewSourceRoot}/current/.venv/bin/kirocrew"
    else
      "%h/.local/bin/kirocrew";
in
{
  # KiroCrew uses an isolated Python launched with -E, so PYTHONTZPATH is
  # ignored. Keep tzdata pinned inside the pipx environment across reinstalls.
  # NOTE: The kirocrew venv was installed with backend=uv (baked into pipx
  # metadata), so we use uv directly to inject packages. pipx inject refuses to
  # override the recorded backend even with PIPX_DEFAULT_BACKEND=pip.
  # UV_NO_CONFIG prevents uv from traversing parent dirs for config files
  # (hits permission errors when activation runs as root).
  home.activation.kirocrewTzdata = lib.mkIf (!useSourceInstall) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      kirocrewPython="$HOME/.local/share/pipx/venvs/kirocrew/bin/python"
      if [ -x "$kirocrewPython" ]; then
        installedVersion="$("$kirocrewPython" -c 'from importlib.metadata import version; print(version("tzdata"))' 2>/dev/null || true)"
        if [ "$installedVersion" != "${kirocrewTzdataVersion}" ]; then
          $DRY_RUN_CMD env UV_NO_CONFIG=1 ${pkgs.uv}/bin/uv pip install --python "$kirocrewPython" "tzdata==${kirocrewTzdataVersion}"
        fi
      fi
    ''
  );

  # glab is installed system-wide by nixos/kirocrew.nix (root-owned symlink
  # at /usr/local/libexec/kirocrew/glab). No sudo needed here.

  # On headless hosts, the KiroCrew gateway runs as a system service under
  # the dedicated kirocrew user (nixos/kirocrew-services.nix). The user-level
  # service is only used on workstation profiles.
  systemd.user.services.kirocrew = lib.mkIf (cfg.role == "workstation") {
    Unit = {
      Description = "KiroCrew Gateway";
      After = [ "network-online.target" ] ++ lib.optionals hasSops [ "sops-nix.service" ];
      Wants = lib.optionals hasSops [ "sops-nix.service" ];
    };
    Service = {
      Type = "simple";
      ExecStartPre =
        lib.optionals useSourceInstall [
          "${kirocrewSourceUpdate}/bin/kirocrew-source-update"
        ]
        ++ [
          "${pkgs.coreutils}/bin/mkdir -p %t/kirocrew-tmp"
          "${kirocrewExecutable} config set --local agent.sandbox strict"
        ];
      ExecStart = "${kirocrewExecutable} gateway";
      # A first source install builds the TypeScript dashboard and Python venv.
      TimeoutStartSec = "20min";
      Restart = "always";
      RestartSec = 5;
      Environment = [
        "KIROCREW_HOME=%h/.kiro/crew"
        "PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo"
        "TMPDIR=%t/kirocrew-tmp"
        "XDG_RUNTIME_DIR=%t"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        "SSH_AUTH_SOCK=%h/.1password/agent.sock"
        "PATH=%h/.local/bin:/etc/profiles/per-user/orre/bin:%h/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "LD_LIBRARY_PATH=${kirocrewLibraryPath}"
        "KIROCREW_BIND=0.0.0.0"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Refresh stable tags daily. New releases are built and validated alongside
  # the active one; the gateway restarts only after the atomic symlink switch.
  # On headless hosts, the system-level kirocrew-gateway service manages its
  # own installation; this user-level updater is disabled there.
  systemd.user.services.kirocrew-source-update = lib.mkIf (cfg.enable && cfg.role == "workstation") {
    Unit.Description = "Update KiroCrew source release";
    Service = {
      Type = "oneshot";
      ExecStart = "${kirocrewSourceUpdate}/bin/kirocrew-source-update --restart";
      TimeoutStartSec = "20min";
    };
  };

  systemd.user.timers.kirocrew-source-update = lib.mkIf (cfg.enable && cfg.role == "workstation") {
    Unit.Description = "Daily KiroCrew stable-tag check";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
      Unit = "kirocrew-source-update.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
