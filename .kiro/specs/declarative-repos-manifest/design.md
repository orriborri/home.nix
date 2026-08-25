# Design

## Context

Repository cloning currently happens in two completely independent implementations:

1. **Local workstation** (`development.nix:57-74`): reads `$HOME/.config/home-manager/config/repos.toml`, clones with `--depth=1` into `$HOME/<path>`, targets `~/ReadPeak/*`.
2. **EC2 launcher** (`launcher.py:335-417`): hard-codes a list of 5 GitLab repos + pasta, clones into `~/code/readpeak/*`, uses full history, and streams SSH failures inline.

These two implementations:
- Use different repo lists (14 repos locally vs 6 on EC2)
- Use different destination paths (`~/ReadPeak/` vs `~/code/readpeak/`)
- Use different clone depths (shallow vs full)
- Use different SSH key strategies (agent vs sops-decrypted key)

The manifest already exists and works locally. The EC2 side just ignores it.

## Goals / Non-Goals

**Goals:**
- Make the EC2 launcher read `repos.toml` from the remote's XDG path (placed by `kirocrew-config.nix`)
- Converge on one destination convention
- Add optional `targets` and `shallow` fields to control per-host behavior
- Keep the format backward-compatible (new fields are optional)

**Non-Goals:**
- Auto-pulling on switch (too slow, breaks offline activation)
- Deleting repos removed from the manifest (destructive)
- Managing repo branches or worktrees
- Replacing the launcher's SSH key bootstrapping (that remains in sops.nix)

## Decisions

### 1. Converge destination to `~/code/readpeak/` (lowercase)

The EC2 launcher already uses `~/code/readpeak/`. Migrate the manifest to match:

```toml
[[repos]]
remote = "git@gitlab.com:readpeak/mononode.git"
path = "code/readpeak/mononode"
```

The old `ReadPeak/` paths become aliases during a transition period (the activation checks both).

**Rationale:** Lowercase is conventional on Linux. The EC2 launcher and code-review-graph already use this path. Converging toward the existing remote convention means less churn on the deployed host.

**Alternative:** Keep `~/ReadPeak/` -- rejected because it conflicts with the live EC2 layout.

### 2. Extended manifest format

```toml
# config/repos.toml

[settings]
base_dir = "code/readpeak"   # default prefix for repos without explicit path

[[repos]]
remote = "git@gitlab.com:readpeak/mononode.git"
path = "code/readpeak/mononode"
shallow = false
# targets omitted = clone everywhere

[[repos]]
remote = "git@gitlab.com:readpeak/renovate-bot.git"
path = "code/readpeak/renovate-bot"
shallow = true
targets = ["workstation"]  # not needed on headless agent host

[[repos]]
remote = "git@github.com:orriborri/pasta.git"
path = "code/pasta"
```

New optional fields:
- `shallow` (bool, default `true`): whether to use `--depth=1`
- `targets` (array of strings, default `["workstation", "headless"]`): which roles clone this repo

**Rationale:** Backward compatible. Existing entries without new fields keep working. The activation and launcher both parse the same format.

### 3. Activation script reads `targets` and skips non-matching repos

The activation script receives the host's role via an environment variable set by `kirocrew-config.nix`:

```nix
home.sessionVariables.KIROCREW_ROLE = cfg.role;
```

The Python snippet then filters:

```python
role = os.environ.get("KIROCREW_ROLE", "workstation")
for repo in data.get("repos", []):
    targets = repo.get("targets", ["workstation", "headless"])
    if role not in targets:
        continue
    ...
```

**Rationale:** Simple filtering with no Nix evaluation needed at runtime.

### 4. EC2 launcher reads manifest from the remote

After `nixos-rebuild switch` places `repos.toml` at `~/.config/kirocrew/repos.toml` on the remote, the launcher reads it:

```python
def _read_repos_manifest(self, remote: RemoteHost) -> list[dict]:
    raw = remote.run("orre", "cat ~/.config/kirocrew/repos.toml", capture=True).stdout
    return tomllib.loads(raw).get("repos", [])
```

Then `_sync_repositories` iterates the parsed list instead of its hard-coded entries.

**Rationale:** Eliminates the hard-coded list. Adding a repo to the TOML is sufficient.

### 5. `crgRegisterRepos` derives scan paths from manifest

Instead of hard-coding `$HOME/ReadPeak`:

```nix
home.activation.crgRegisterRepos = lib.hm.dag.entryAfter [ "cloneRepos" "uvTools" ] ''
  CRG="$HOME/.local/bin/code-review-graph"
  MANIFEST="$HOME/.config/kirocrew/repos.toml"
  if [ -x "$CRG" ] && [ -f "$MANIFEST" ]; then
    ${pkgs.python3}/bin/python3 -c "
import tomllib, os, subprocess, sys
with open(sys.argv[1], 'rb') as f:
    repos = tomllib.load(f).get('repos', [])
home = os.path.expanduser('~')
crg = sys.argv[2]
for repo in repos:
    target = os.path.join(home, repo['path'])
    if os.path.isdir(os.path.join(target, '.git')):
        subprocess.run([crg, 'register', target], capture_output=True)
" "$MANIFEST" "$CRG"
  fi
'';
```

**Rationale:** Single source of truth. No scan directory hard-coded anywhere.

## Risks / Trade-offs

- **[Breaking path change]** Existing repos at `~/ReadPeak/` won't be automatically moved. Mitigation: document the migration; keep both paths valid during transition; activation only clones if target doesn't exist.
- **[Larger clone set on EC2]** The full manifest has 14 repos vs the current 6. Mitigation: use `targets = ["workstation"]` on repos the headless agent doesn't need (wiki, renovate-bot, etc.).
- **[TOML on remote requires Python]** The launcher already uses Python, and the remote has Python via pipx/kirocrew. `tomllib` is stdlib on 3.11+. No risk.
- **[Manifest is immutable at runtime]** Since it's placed via `xdg.configFile`, you can't add a repo on the remote without a rebuild. Mitigation: this is intentional -- repos are operator-declared, not runtime-discovered.
