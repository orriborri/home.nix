# KiroCrew Skills & Agents Loading — Findings

## Implementation and live verification — 2026-09-08

The analysis below records the pre-repair state. Option A has now been
implemented in `scripts/kirocrew_skill_sync.py`, packaged by
`kirocrew-skills-package.nix`, and shared by the NixOS and Home Manager services.

- Matt's pinned revision is `3cca18b368ae95cdbdebbff572ccafa662551015`.
  It contains **37 nested skills**, including `engineering/tdd/SKILL.md`.
  All relative paths and bundled resources are retained.
- The original proposed `cp -a` snippet was insufficient: it misses resource-only
  updates, retains removed files, and copies setgid directory modes from the
  shared EC2 checkout that `RestrictSUIDSGID` rejects. The helper compares full
  tree contents and ordinary permissions, stages replacements, and strips special
  mode bits. It does not copy ownership or extended filesystem attributes.
- Ownership fingerprints live in `skill-sync/mattpocock/manifest.json` next to
  the skills directory. Conflicting edits are preserved and reported; replaced
  or removed managed trees are archived outside discovery. Symlinks, path
  traversal, overlapping skills, and missing/empty sources fail closed.
- `scripts/kirocrew_pinned_repo.py` adds actual immutable-revision fetch/checkout
  support. It retains protected-mirror separation on EC2. A checkout already at
  the requested revision is left alone; changing revisions preserves dirty or
  locally committed work. The installer separately requires a clean `skills/`
  subtree at the pinned HEAD, including rejecting ignored extra resources.
- The workstation module is **`../kirocrew-service.nix`**. It now runs the same
  helper with a 15-minute user timer. Public HTTPS fetching ignores the operator's
  global SSH URL rewrites, so scheduled runs do not require interactive signing.
  `../development.nix` leaves pinned checkouts to this service.
- Both deployed gateways' authenticated `/api/skills` responses include **all
  37 managed skill keys**, with none missing. The bundled diagnosing-bugs script
  is present and readable (1,316 bytes). The EC2 service succeeded twice in a row;
  the workstation service/timer and both gateways are healthy.
- EC2 runs KiroCrew **v0.5.0**. Its source confirms directory discovery and runtime
  enumeration. It also supports **`skills.extra_paths`** (read-only extra sources):
  this is a third sourcing option omitted from the original analysis. No
  `KIROCREW_PROJECT_DIR` change was made. Evaluate extra paths separately before
  making future claims that the native project directory is the only option.
- `sync-state` still targets `orre`'s legacy home rather than the dedicated
  system gateway home. Its seed-only behavior and custom agent management remain
  separate decisions.

Before repair, EC2 skills were snapshotted to
`/var/lib/kirocrew/.kiro/crew/skill-sync/pre-repair.dn75j9/skills.tar.gz`.
Identical flattened files were moved into `skill-sync/mattpocock/legacy-*`;
no differing legacy files were removed. Prior managed versions retain
`metadata.json` with their relative name and previous fingerprint for rollback.
Archives are retained for manual review, not automatically pruned.

See `todo.md` for completion status and validation commands. The historical
findings and initial proposal follow.

Investigation into how this repo loads agent skills and agents into the KiroCrew
gateway, checked against the authoritative KiroCrew source and docs
(`kirodotdev/KiroCrew@main`, fetched via `gh`).

## TL;DR

- **Skills are directory-per-skill**, keyed on a file literally named `SKILL.md`:
  `~/.kiro/crew/skills/<name>/SKILL.md` (nested paths allowed, e.g.
  `code/code-review/SKILL.md`). The whole directory travels (scripts, assets).
- **Our `kirocrew-skill-sync.service` is broken**: it flattens
  `<slug>/SKILL.md` → `<slug>.md` in the skills root. The gateway loader never
  discovers a flat `<slug>.md`, so the synced Matt Pocock skills are **not
  loaded at all** on the headless/EC2 gateway. It also drops bundled
  `scripts/`/`assets/` because it copies only the single `SKILL.md`.
- **Agents** are not managed by our pipeline at all. In KiroCrew they are
  `agents/<name>.json` (or CLI-side `.kiro/agents/<name>.{json,md}`). We only
  append `agent.subagent_cwd_allowed_roots` in `launcher.py`.
- The **launcher's `_sync_state`** path is correct on layout (tars whole
  directories) but is additive-only and manual.

---

## 1. Authoritative layout (from KiroCrew source)

### Skill loader — `src/kiro_crew/skills.py`

`SkillsLoader` docstring and `_iter_skill_files()`:

```
~/.kiro/crew/skills/
├── learn/SKILL.md
├── subagent/SKILL.md
├── code/
│   ├── code-review/SKILL.md
│   └── code-task-generation/SKILL.md
└── utils/
    ├── url-shortener/SKILL.md
    └── mcp-debug/SKILL.md
```

- `_iter_skill_files(base)` walks `base` with `os.walk` and **only registers a
  skill when `"SKILL.md" in files`**. A directory without a `SKILL.md` is
  skipped.
- The skill's **name is its parent directory** relative to the base:
  `skill_file.parent.relative_to(base)`, `/`-separated. So `a/b/SKILL.md` → name
  `a/b`.
- Consequence: a flat file `skills/tdd.md` is **never discovered**. It is not a
  `SKILL.md` inside any subdirectory. This is exactly what our sync service
  produces.
- Dot-directories (`.archive`, `.pending`, `.versions`) are pruned. Symlink
  containment is enforced (files must resolve within the skills base or a
  trusted provider root).

### Built-in / project auto-copy — `_ensure_builtin_skills(base)`

- Iterates two source roots **in precedence order**:
  ```python
  for src_root in (_project_skills_dir(), _BUILTIN_SKILLS_DIR):
  ```
- `_project_skills_dir()` returns `Path($KIROCREW_PROJECT_DIR) / "skills"` if
  that dir exists, else `None`.
- `_BUILTIN_SKILLS_DIR = Path(__file__).parent / "builtin_skills"` — bundled in
  the wheel, packaged and copied into every install on gateway start.
- **Copies entire skill directories** (scripts, assets, nested paths), not just
  `SKILL.md`.
- **Project skills win name collisions** — the project dir is iterated first;
  "first source root to ship a name owns it for this run."
- **Runs on every gateway startup** in a worker thread
  (`asyncio.to_thread` around `SkillsLoader()`), mtime/fingerprint-guarded so
  steady state re-copies nothing. Not a literal "first run only".
- **Provenance-gated destruction**: a destination is only replaced/removed when
  verifiably an unchanged copy this sync installed. User-edited or
  user-added trees are preserved — quarantined to `<name>.user-backup` on
  update, or left alone. So a manually-placed skill is safe from being
  clobbered.

### Skills README — `skills/README.md`

- "Each skill is a directory containing a `SKILL.md` file."
- Repo `skills/` is **checkout-only**: synced into `~/.kiro/crew/skills` only
  when `KIROCREW_PROJECT_DIR` points at that checkout, and NOT part of the
  wheel. A skill any shipped feature references must live in
  `kiro_crew/builtin_skills/` instead.
- Frontmatter fields:

  | Field | Required | Notes |
  |-------|----------|-------|
  | `name` | yes | defaults to directory name if omitted |
  | `description` | yes | one-line; LLM uses it to decide relevance |
  | `always` | no | `true` injects into every session (default false) |
  | `triggers` | no | comma-separated keywords; `!` prefix = negative trigger |
  | `repo_scope` | no | relative path that must exist in the session's active project (fails closed) |
  | `inject_on_trigger` | no | `false` keeps a trigger match index-only (read on demand) |

  Provenance keys (`source`, `session_key`, `created_at`, `refined_at`,
  `reuse_count`, `pinned`, `version`) are written by the installer/editor — do
  not hand-edit. Unknown fields are ignored (so a misspelled field fails
  silently).

- Loading behavior: `always:true` → full content at session start; `triggers`
  match → full content injected; no match → summary only, LLM can `cat` on
  demand.
- No rebuild required — skills read at runtime, changes take effect next session.

## 2. KiroCrew system spec — `docs/system-specs/modules/memory-skills-hooks.md`

- Line 744: "Markdown files at `~/.kiro/crew/skills/{name}/SKILL.md` with
  optional YAML frontmatter (`name`, `description`, `always`)."
- Line 750: "Source precedence (project-level wins):
  `$KIROCREW_PROJECT_DIR/skills/` → `builtin_skills/` (bundled). Auto-copied to
  `~/.kiro/crew/skills/` on first run. **Copies entire skill directories
  (scripts, assets, etc.).**"
- Project skills also come from `<project>/.kiro/skills` (a *different* source
  from `$KIROCREW_PROJECT_DIR/skills/`), gated by a per-directory trust grant at
  `<data home>/trust/project-skills.json`. `repo_scope` for skills uses the same
  gate as scoped memory lessons.

## 3. CLI skills doc — `docs/reference/kiro-cli/skills.md`

Different surface from the gateway (IDE/CLI):

- Locations: `.kiro/skills/` (workspace), `~/.kiro/skills/` (global) — **no
  `crew/` segment**.
- Layout: `pr-review/SKILL.md` + optional `scripts/`, `references/`, `assets/`.
- Every skill is also a slash command (`/pr-review`); `$ARGUMENTS`/`$`
  placeholder substitution is CLI-only.
- Custom agents do NOT auto-load skills — must opt in via
  `skill://.kiro/skills/*/SKILL.md` in the agent's `resources`.
- Frontmatter: `name` (must match folder, lowercase/numbers/hyphens, ≤64 chars),
  `description` (≤1024), optional `license`, `compatibility`, `metadata`.

## 4. Custom agents — `docs/reference/kiro-cli/custom-agents/README.md`

- JSON or Markdown, identical fields (Markdown = front matter + prompt body).
- Live at `.kiro/agents/<name>.{json,md}` (workspace) or `~/.kiro/agents/`
  (global); workspace wins collisions; workspace agent loads only if workspace
  is trusted.
- Nested dirs supported; name = extension-less path relative to agents dir
  (`~/.kiro/agents/team/planner.md` → `team/planner`).
- App-kit examples confirm gateway/app agents are `agents/<name>.json`
  (`greeter.json`, `ticket-analyst.json`; built-ins `discovery.json`,
  `pr-author.json`).

---

## 5. What this repo does today

### `config/repos.toml`

- Clones `github.com/mattpocock/skills` → `code/mattpocock-skills`,
  `targets = ["headless"]`, `graph = false`.
- Fields: `remote`, `path`, `shallow` (default true), `targets` (default
  `["workstation","headless"]`), `graph` (default true).
- The skills repo is **not cloned on workstation** (headless only) and is **not
  pinned** to a ref (floats on upstream default branch).

### `kirocrew-code.nix` — `kirocrew-skill-sync.service` (BROKEN)

- Triggered by `repo-sync.service` `onSuccess`/`onFailure`.
- Walks `find "$source_dir" -name 'SKILL.md'`, then:
  ```sh
  skill_name="$(basename "$skill_dir")"     # e.g. "tdd"
  dest="$skills_dir/$skill_name.md"         # → skills/tdd.md   ← FLATTENED
  cp "$skill_file" "$dest"                   # only SKILL.md, drops scripts/assets
  ```
- Result `skills/<slug>.md` is invisible to the loader (needs
  `skills/<slug>/SKILL.md`). Bundled resources lost.
- `source_dir = ${codeDir}/mattpocock-skills/skills`,
  `skills_dir = /var/lib/kirocrew/.kiro/crew/skills`, `codeDir = /var/lib/code`.

### `kirocrew_ec2/launcher.py` — `_sync_state` (workstation → EC2 push)

- Command: `./nixos/launch-ec2 sync-state`
  ("sync local kirocrew config, skills, and workspace to remote").
- Pushes from local `~/.kiro/crew/` to remote `~/.kiro/crew/` as user `orre`:
  1. `config.json` — backed up to `config.json.bak`, then overwritten (contains
     auth tokens).
  2. `skills/` — **additive only**: `missing = local - remote`; sends only
     missing skill directories via `tar` (whole directories, correct layout).
     Updates and deletions do NOT propagate.
  3. `workspace/{memory,tasks,knowledge}` — pushed wholesale via `tar` overlay.
- Correct on layout, but manual + one-shot + additive-only. Good for seeding a
  fresh instance, not continuous reconciliation.
- Related commands: `migrate-kirocrew` (snapshot + rollback migration),
  `auth <target>` (MCP OAuth: linear, metabase).

### Agents

- Not managed declaratively anywhere.
- `launcher.py::_register_project_dirs` appends `/var/lib/code` and
  `/var/lib/vault` to `agent.subagent_cwd_allowed_roots` (subagent sandbox
  plumbing only).

### `KIROCREW_PROJECT_DIR`

- **Not set anywhere** in the Nix modules. The gateway service
  (`kirocrew-services.nix`) sets `KIROCREW_HOME=/var/lib/kirocrew/.kiro/crew`,
  `HOME`, `KIROCREW_BIND`, `KIROCREW_DEVFLEET_BIN_GIT`, `SSH_AUTH_SOCK`, etc.,
  but not `KIROCREW_PROJECT_DIR`. So the native project-skills auto-copy path is
  dormant — which is likely why the (broken) sync service was written to
  compensate.

### Workstation gateway module

- Docs (`kirocrew.md`) reference a Home Manager module `kirocrew-service.nix`
  (singular) as the workstation gateway service, but it is **not present in this
  `nixos/` directory**. Only `kirocrew-services.nix` (plural, the EC2/headless
  system service) exists here. The workstation module may live elsewhere in the
  home-manager config. Not yet located/verified.

---

## 6. Options to fix skill loading

### Option A — fix the sync service to mirror directories (low risk, recommended)

Change `kirocrew-skill-sync.service` to copy the whole `<slug>/` directory,
keeping `SKILL.md` as the filename:

```sh
while IFS= read -r -d "" skill_file; do
  skill_dir="$(dirname "$skill_file")"
  skill_name="$(basename "$skill_dir")"
  dest="$skills_dir/$skill_name"
  if [[ ! -e "$dest/SKILL.md" ]] || [[ "$skill_file" -nt "$dest/SKILL.md" ]]; then
    mkdir -p "$dest"
    cp -a "$skill_dir/." "$dest/"     # whole skill: SKILL.md + scripts/ + assets
    synced=$((synced + 1))
  fi
done < <(find "$source_dir" -name 'SKILL.md' -print0)
```

- Keeps the existing declarative `repos.toml` + `repo-sync` trigger.
- Does NOT touch `KIROCREW_PROJECT_DIR` semantics.
- Caveat: if Matt's repo nests skills more than one level deep, `basename`
  collapses `a/b` → `b` and could collide; preserve the relative path under
  `source_dir` instead of just the basename. **Not yet verified** whether the
  repo nests.

### Option B — use the native `KIROCREW_PROJECT_DIR` auto-copy

Set `KIROCREW_PROJECT_DIR=/var/lib/code/mattpocock-skills` on the gateway
service so the loader reads `.../mattpocock-skills/skills/` and auto-copies on
every startup (correct layout, self-reconciling, provenance-safe).

- **Risk / caveat**: `KIROCREW_PROJECT_DIR` is the gateway's notion of *the*
  project directory, not just a skills source. It likely also affects session
  default cwd, project-scoped memory/lessons, and `repo_scope` gating. Pointing
  it at the skills repo — when real code repos are the actual agent workspaces —
  is probably wrong. Its non-skills consumers are **not yet traced**.
- There is no separate "extra skills dir" env var; native project skills come
  only via `KIROCREW_PROJECT_DIR` or the bundled (read-only) `builtin_skills/`.

### Recommendation

Given multiple real code repos are the agent workspaces, prefer **Option A**
(directory-mirror fix) over pinning `KIROCREW_PROJECT_DIR` to the skills repo.
For the workstation: add `"workstation"` to the `mattpocock-skills` `targets`
and mirror directories into `~/.kiro/crew/skills/<slug>/` from the checkout via
the Home Manager module.

---

## 7. Open questions / unverified

1. Does `mattpocock/skills` nest skills deeper than one level (affects Option A
   `basename` collision handling)?
2. Where is the workstation `kirocrew-service.nix` Home Manager module, and does
   it already handle skills? Is `repos.toml` consumed on the workstation
   profile?
3. Full set of `KIROCREW_PROJECT_DIR` consumers in the source (needed to make an
   evidence-based A-vs-B call).
4. Can `_sync_state` be made non-additive for skills so updates propagate, or is
   one-shot seed behavior sufficient?

## Sources

- `github.com/kirodotdev/KiroCrew@main`:
  - `src/kiro_crew/skills.py` (`SkillsLoader`, `_iter_skill_files`,
    `_ensure_builtin_skills`, `_project_skills_dir`)
  - `skills/README.md`
  - `docs/system-specs/modules/memory-skills-hooks.md` (lines 744, 750)
  - `docs/reference/kiro-cli/skills.md`
  - `docs/reference/kiro-cli/custom-agents/README.md`
  - app-kit examples: `docs/app-kit/examples/{minimal,full}-app/{agents,skills}/`
- This repo: `config/repos.toml`, `nixos/kirocrew-code.nix`,
  `nixos/kirocrew-services.nix`, `nixos/kirocrew_ec2/launcher.py`,
  `nixos/kirocrew_ec2/cli.py`, `nixos/kirocrew.md`
