# Design

## Context

The KiroCrew EC2 host is deployed declaratively via `nixos-rebuild switch --flake .#kirocrew-ec2`. The Nix evaluation produces the full system and user configuration without needing a repo checkout on the remote. However, several non-Nix files that the gateway and activation scripts consume are currently:

- Read from a hard-coded checkout path (`$HOME/.config/home-manager/config/repos.toml`) that only works on the local workstation
- Injected imperatively by the EC2 launcher (`_sync_repositories` hard-codes a different repo list; `known_hosts` is built on-the-fly)
- Split across different conventions (local reads TOML, launcher ignores it and hard-codes repos)

The goal is to consolidate static, non-secret configuration into one declarative Home Manager module so it flows through Nix evaluation onto any target host.

## Goals / Non-Goals

**Goals:**
- Place `repos.toml` at a well-known XDG path that both local and remote consumers use
- Declaratively install SSH known_hosts for GitLab/GitHub
- Provide a `role` option so platform-specific logic uses explicit flags instead of `builtins.pathExists`
- Keep the module composable: importable by workstation, VM, EC2, and AMI profiles

**Non-Goals:**
- Managing `~/.kiro/crew/config.json` (contains auth tokens -- stays runtime-synced)
- Managing `~/.kiro/crew/skills/` or `workspace/` (mutable application state)
- Replacing sops-nix for secrets
- Packaging the KiroCrew CLI as a Nix derivation (separate spec)

## Decisions

### 1. New file: `kirocrew-config.nix` (module-style)

A new root-level module imported by `home.nix`'s `imports` list. It uses `lib.mkOption` to declare a `kirocrew.role` option.

```nix
# kirocrew-config.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.kirocrew;
in
{
  options.kirocrew = {
    enable = lib.mkEnableOption "KiroCrew declarative configuration";
    role = lib.mkOption {
      type = lib.types.enum [ "workstation" "headless" ];
      default = "workstation";
      description = "Target host role. Headless omits desktop-specific config.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."kirocrew/repos.toml".source = ./config/repos.toml;

    # SSH known_hosts for Git forges
    home.file.".ssh/known_hosts_kirocrew" = {
      text = ''
        gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfRKE...
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnk...
      '';
    };
  };
}
```

**Rationale:** Module-style with options keeps it composable and testable. The `enable` guard prevents accidental activation in profiles that don't need KiroCrew.

**Alternative:** Function-style assigned under `programs` -- rejected because this isn't a single program config but cross-cutting configuration.

### 2. `development.nix` reads from XDG path

Replace the hard-coded `$HOME/.config/home-manager/config/repos.toml` with `$HOME/.config/kirocrew/repos.toml`.

```nix
home.activation.cloneRepos = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  MANIFEST="$HOME/.config/kirocrew/repos.toml"
  ...
'';
```

**Rationale:** The XDG path is guaranteed to exist on any host where `kirocrew-config.nix` is imported, regardless of whether a git checkout exists at `~/.config/home-manager`.

### 3. EC2 launcher reads the same manifest

The launcher's `_sync_repositories` method currently hard-codes a smaller repo list. It should instead:
1. Read `repos.toml` from the remote's `~/.config/kirocrew/repos.toml` (placed by Nix)
2. Parse the same TOML format
3. Clone/pull each entry

This eliminates the two-list divergence.

**Rationale:** Single source of truth. Adding a repo means editing one TOML file.

**Alternative:** Keep the launcher list separate -- rejected because it already drifts.

### 4. Known-hosts via `programs.ssh.knownHosts`

Home Manager has `programs.ssh.knownHosts` which generates entries into `~/.ssh/known_hosts`. Use this instead of a separate `home.file`:

```nix
programs.ssh.knownHosts = {
  "gitlab.com".publicKey = "ssh-ed25519 AAAAC3...";
  "github.com".publicKey = "ssh-ed25519 AAAAC3...";
};
```

**Rationale:** Uses the idiomatic Home Manager mechanism. Merges with any other known_hosts entries from `security.nix`.

### 5. Role passed explicitly per profile

In `flake.nix`, each `mkHome` call or NixOS HM module sets the role:

```nix
# EC2 profile
home-manager.users.orre = { ... }: {
  imports = [ ./home.nix ./kirocrew-config.nix ... ];
  kirocrew.enable = true;
  kirocrew.role = "headless";
};
```

**Rationale:** Explicit is better than probing the evaluator filesystem with `builtins.pathExists`. The role is known at flake definition time.

## Risks / Trade-offs

- **[Rigidity]** `xdg.configFile` content is immutable (Nix store symlink). If KiroCrew or a script tries to write to `repos.toml` at runtime it will fail. Mitigation: `repos.toml` is only edited by the operator in the git repo, never at runtime.
- **[Migration]** Existing `development.nix` activation will break if the path changes before the new module is imported. Mitigation: make the activation try both paths with fallback during transition.
- **[Launcher changes]** The EC2 launcher is Python; it needs a TOML parser. Mitigation: Python 3.11+ has `tomllib` in stdlib (already used by `development.nix`).
