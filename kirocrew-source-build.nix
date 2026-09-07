{
  pkgs,
  lib,
}:

# Shared KiroCrew source builder.
#
# Produces a `kirocrew-source-update` executable that clones the public
# KiroCrew repository, selects a stable tag (pinned or newest), builds it with
# `make build`, and atomically flips a `current` symlink plus a
# `$HOME/.local/bin/kirocrew` convenience link.
#
# Both the workstation (Home Manager user service, kirocrew-service.nix) and
# the headless/EC2 host (NixOS system service, nixos/kirocrew-services.nix)
# consume this so the two profiles build from source identically.
#
# Everything is derived from $HOME at runtime, so the same package works for
# any user (operator `orre` or the dedicated `kirocrew` system user); only the
# pinned tag is baked in at build time.
#
# Arguments:
#   pinnedSourceTag : "" to follow the newest stable tag, or "vX.Y.Z" to pin.
#   restartUnit     : systemd unit to try-restart when `--restart` is passed
#                     and a new release was built. Empty disables restart.
#   restartScope    : "--user" for a user unit, "" (default) for system.

{
  pinnedSourceTag ? "",
  restartUnit ? "",
  restartScope ? "",
}:

let
  kirocrewTzdataVersion = "2026.3";
in
pkgs.writeShellApplication {
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
    sourceRoot="$HOME/.local/share/kirocrew-source"
    repository="$sourceRoot/repository"
    releases="$sourceRoot/releases"
    current="$sourceRoot/current"
    pinnedTag=${lib.escapeShellArg pinnedSourceTag}
    restartUnit=${lib.escapeShellArg restartUnit}
    restartScope=${lib.escapeShellArg restartScope}
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
    if [ "$restartMode" = "--restart" ] && [ "$updated" -eq 1 ] && [ -n "$restartUnit" ]; then
      # shellcheck disable=SC2086
      systemctl $restartScope --no-block try-restart "$restartUnit"
    fi
  '';
}
