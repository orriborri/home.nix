# TODO — KiroCrew Skills & Agents Loading

Actionable items from the skills/agents loading investigation.
See `kirocrew-skills-findings.md` for the full analysis and source references.

## Validation and recovery

- `python3 -m unittest discover -s tests`: 14 passing integration tests using
  temporary skill trees and local Git repositories. Covers nested resources,
  updates/removals, idempotency, conflicts, links/traversal, pinned revisions,
  dirty sources/local commits, legacy archives and restricted permission copying.
- `ruff check` and `ruff format --check` for the two scripts and their tests;
  `nixfmt --check` for the changed Nix modules; `git diff --check`.
- `nix flake check path:/home/orre/.config/home-manager --no-update-lock-file`.
- `home-manager build --flake path:/home/orre/.config/home-manager#orre`.
- EC2 build/dry activation and both live activations use an isolated snapshot of
  tracked files plus only this task's changes at
  `/tmp/kirocrew-skills-build.AyLPSl`. Existing launcher changes were excluded.
- EC2 activation: `nix run --inputs-from path:/tmp/kirocrew-skills-build.AyLPSl
  nixpkgs#nixos-rebuild -- switch --flake
  path:/tmp/kirocrew-skills-build.AyLPSl#kirocrew-ec2 --build-host root@kirocrew
  --target-host root@kirocrew`.
- Workstation activation: `home-manager switch --flake
  path:/tmp/kirocrew-skills-build.AyLPSl#orre`.
- Both live dashboard APIs enumerate all 37 managed skills; the same bundled
  script is readable on each host. EC2 service reruns successfully without
  reinstalling unchanged skills. Workstation timer runs every 15 minutes.
- Final EC2 check: `repo-fetch`, `repo-sync`, and `kirocrew-skill-sync` all
  report success; the protected mirror pin and working checkout both resolve to
  the configured revision. All 37 old flattened files were archived.
- Final deployed EC2 system:
  `/nix/store/h3xzikcgsfvr69yh41bwwj90l6i7xj70-nixos-system-kirocrew-26.11.20260823.56c02bc`.
- The earlier EC2 build finished remotely, but copying its ARM closure back to
  the workstation ended with an SSH EOF. Subsequent remote-target dry activation
  and switches succeeded; deployment does not depend on that copy-back.
- EC2 pre-repair snapshot:
  `/var/lib/kirocrew/.kiro/crew/skill-sync/pre-repair.dn75j9/skills.tar.gz`.
  Per-skill prior versions and legacy flattened files are retained under
  `skill-sync/mattpocock/`, outside loader discovery. Stop the sync service before
  a manual restore; preserve the ownership manifest together with its skill tree.
- The workstation's pre-existing `vault-sync.service` failure is outside this
  repair. No vault changes were made. The flake has no `orre-minimal` profile;
  no minimal profile activation was attempted.

## P0 — Gateway repair (completed 2026-09-08)

- [x] Replace flattened copies with the shared directory reconciler in
      `scripts/kirocrew_skill_sync.py`. Preserve relative paths, resources and
      executable permissions. Track ownership; archive unchanged managed
      replacements/removals; preserve user edits and unmanaged collisions.
- [x] Verify under the existing systemd `ReadWritePaths` and
      `RestrictSUIDSGID` settings. Strip special mode bits from shared-checkout
      directories instead of weakening the service sandbox.
- [x] Deploy and verify: EC2 service succeeds on repeated runs, and its live
      authenticated dashboard API lists all 37 managed skills. Bundled script
      verified readable. Archive identical flattened files outside discovery.

## P1 — Reproducible sourcing

- [x] Verify nesting: 37 skills under `engineering/`, `in-progress/`, `misc/`,
      and `productivity/`. Preserve all relative paths.
- [x] Pin `../config/repos.toml` to
      `3cca18b368ae95cdbdebbff572ccafa662551015`; implement revision support
      through protected fetch and local checkout, including shallow repositories.
      Refuse to publish a mismatched or modified source subtree.

## P2 — Workstation parity

- [x] Locate `../kirocrew-service.nix` and the clone-only activation in
      `../development.nix`.
- [x] Add the workstation target and supervised refresh service/user timer.
      Public HTTPS fetch works without the interactive SSH agent.
- [x] Activate Home Manager; verify service success, active timer and gateway,
      and all 37 managed skills through the live authenticated dashboard API.

## P3 — Decisions / investigation (not yet actionable)

- [x] **Select Option A for this repair.** Approved and implemented.
- [ ] Before considering Option B
      (`KIROCREW_PROJECT_DIR=/var/lib/code/mattpocock-skills`), trace all
      non-skills consumers of `KIROCREW_PROJECT_DIR` in the KiroCrew source
      (session cwd, project-scoped memory/lessons, `repo_scope` gating). Pinning
      it to the skills repo when real code repos are the agent workspaces is
      likely wrong. Also evaluate `skills.extra_paths`, confirmed in installed
      v0.5.0: the original analysis omitted this native read-only source option.
- [ ] **Decide whether `_sync_state` skills push should be non-additive.**
      Currently additive-only (`missing = local - remote`); updates and deletions
      don't propagate. It targets `orre`'s legacy home, not the system gateway's
      `/var/lib/kirocrew/.kiro/crew`; settle destination and ownership first. File:
      `nixos/kirocrew_ec2/launcher.py`.
- [ ] **Agents: decide whether to manage custom agents declaratively.** None are
      managed today (only `subagent_cwd_allowed_roots` is appended in
      `launcher.py`). KiroCrew agents are `agents/<name>.json` /
      `.kiro/agents/<name>.{json,md}`. Only needed if custom gateway agents are
      part of the intended setup.

## Reference — verified layout facts

- Skills: `~/.kiro/crew/skills/<name>/SKILL.md` (dir-per-skill, nested paths OK,
  whole dir incl. `scripts/`/`assets/`). Flat `<name>.md` is NOT discovered.
- Native auto-copy `_ensure_builtin_skills` runs every gateway startup (worker
  thread), sources `$KIROCREW_PROJECT_DIR/skills/` then bundled `builtin_skills/`,
  project wins collisions, provenance-gated (won't clobber user-edited trees).
- Frontmatter: `name`, `description` (required), `always`, `triggers` (`!`
  negation), `repo_scope`, `inject_on_trigger`.
- `sync-state` command: `./nixos/launch-ec2 sync-state` pushes local
  `config.json` (overwrite + .bak), `skills/` (additive whole-dir), and
  `workspace/{memory,tasks,knowledge}` to the EC2 instance.
