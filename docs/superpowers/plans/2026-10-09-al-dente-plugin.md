# al-dente Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `al-dente` Claude Code plugin (Pasta MCP + 8 skills + vault rules) from the Readpeak vault repo, usable from any directory on this laptop.

**Architecture:** The vault repo gets a local plugin marketplace (`.claude-plugin/marketplace.json`) whose single plugin lives in `.agent-plugin/`. The plugin loads in place (local-path marketplace), so edits apply on `/reload-plugins`. A committed `check.sh` in the plugin is the test: written first, red, and turned green task by task. The home-manager repo only loses its dead `nixos/pasta-skills*`.

**Tech Stack:** Claude Code plugins (marketplace.json, plugin.json, .mcp.json, skills), bash, git. No Nix in the vault.

**Spec:** `docs/superpowers/specs/2026-10-09-al-dente-plugin-design.md`

## Global Constraints

- Vault root: `~/Obsidian/Readpeak` (git remote `gitlab.com:orriborri/Vault`). Read its `AGENTS.md` before writing to it.
- The vault has unrelated uncommitted changes (`.feeds/*`, `.claude/settings.local.json`) and KiroCrew auto-commits it. Stage only the paths each task names (`git add <paths>`, never `git add -A`/`.`), and never commit `.feeds/` or `.claude/settings.local.json`.
- Marketplace name `orre-vault`; plugin name `al-dente`; plugin root `.agent-plugin/`.
- MCP command: `${HOME}/code/pasta/target/service/release/kb-mcp`, env `RUST_LOG=error`, server name `pasta-kb`.
- The 8 skills, exactly: `daily-note daily-plan llm-wiki pasta-vault personal-agent raw-inbox-memory readpeak-assistant weekly-review`.
- Do not edit `~/code/pasta`. Never push either repo.
- Spec refinement (decided while planning): instead of rewriting every vault-relative path in the moved skills (dozens, see `daily-plan/SKILL.md:20-58`, `weekly-review/SKILL.md:29-99`), each vault skill gets one line under its H1: ``Vault root: `~/Obsidian/Readpeak`. Paths below are relative to it.`` Same effect, a 1-line diff per skill. Eval fixtures under `evals/` keep relative paths (they are fixture-relative). Task 5 updates the spec to match.

## Review Focus

1. **Inside the vault, skills load twice** (plugin + `.claude/skills`): expect each skill once. Pinned by `check.sh` (Task 2: `.claude/skills` must not exist).
2. **Stale `~/.claude/skills/{personal-agent,raw-inbox-memory}` shadow the plugin's newer copies**: expect the plugin's version. Pinned by Task 6 Step 2 (`ls` must show neither).
3. **`kb-mcp` missing during a pasta rebuild**: expect the MCP to show failed and skills to still answer from vault files. Pinned by Task 6 Step 6 (check `claude mcp list` wording, and that `/al-dente:daily-plan` still works when the MCP is down is noted, not forced).
4. **`readpeak-assistant` triggering in unrelated repos** (for example a TypeScript refactor in mononode): expect it to stay unloaded. Pinned by Task 3's description, which names vault/planning/ops/Pasta triggers only; `check.sh` asserts the description contains "Readpeak vault".
5. **KiroCrew auto-commit sweeping in half-done plugin files**: expect only complete task commits. Pinned by each commit step's `git status --short .agent-plugin .claude-plugin .claude/skills .agents` check before committing.

---

### Task 1: Plugin skeleton and the check script

**Files:**
- Create: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
- Create: `~/Obsidian/Readpeak/.claude-plugin/marketplace.json`
- Create: `~/Obsidian/Readpeak/.agent-plugin/.claude-plugin/plugin.json`
- Create: `~/Obsidian/Readpeak/.agent-plugin/.mcp.json`
- Create: `~/Obsidian/Readpeak/.agent-plugin/README.md`

**Interfaces:**
- Produces: `check.sh` (exit 0 = plugin complete; each failure prints `FAIL: …`), used by every later task.

- [ ] **Step 1: Write the check script (the test)**

`~/Obsidian/Readpeak/.agent-plugin/check.sh`:

```bash
#!/usr/bin/env bash
# Verifies the al-dente plugin layout. Exit 0 = complete.
set -u
V="${VAULT:-$HOME/Obsidian/Readpeak}"
P="$V/.agent-plugin"
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
want="daily-note daily-plan llm-wiki pasta-vault personal-agent raw-inbox-memory readpeak-assistant weekly-review"

claude plugin validate "$P" >/dev/null 2>&1 || err "plugin manifest invalid: claude plugin validate $P"
claude plugin validate "$V" >/dev/null 2>&1 || err "marketplace manifest invalid: claude plugin validate $V"
grep -qF '${HOME}/code/pasta/target/service/release/kb-mcp' "$P/.mcp.json" 2>/dev/null \
  || err ".mcp.json does not run kb-mcp from target/service"

have=$(ls "$P/skills" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
[ "$have" = "$want" ] || err "skills are '$have', want '$want'"
for s in daily-note daily-plan llm-wiki weekly-review readpeak-assistant; do
  grep -qF 'Vault root: `~/Obsidian/Readpeak`' "$P/skills/$s/SKILL.md" 2>/dev/null \
    || err "$s/SKILL.md lacks the vault-root line"
done
grep -q 'Readpeak vault' "$P/skills/readpeak-assistant/SKILL.md" 2>/dev/null \
  || err "readpeak-assistant description does not scope itself to the Readpeak vault"
if grep -rn '\.claude/skills' "$P/skills" >&2; then err "skills still reference .claude/skills"; fi
[ ! -e "$V/.claude/skills" ] || err ".claude/skills still exists (skills would load twice in the vault)"

links=$(ls "$V/.agents/skills" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
[ "$links" = "$want" ] || err ".agents/skills is '$links', want '$want'"
broken=$(find "$V/.agents/skills" -xtype l 2>/dev/null)
[ -z "$broken" ] || err "broken Codex links: $broken"

[ "$fail" = 0 ] && echo "al-dente: all checks passed"
exit "$fail"
```

Run: `chmod +x ~/Obsidian/Readpeak/.agent-plugin/check.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: exit 1 with `FAIL: plugin manifest invalid`, `FAIL: marketplace manifest invalid`, `FAIL: .mcp.json does not run kb-mcp`, plus the skills/links failures.

- [ ] **Step 3: Write the manifests, MCP config and README**

`~/Obsidian/Readpeak/.claude-plugin/marketplace.json`:

```json
{
  "name": "orre-vault",
  "owner": { "name": "Oscar Henriksson" },
  "plugins": [
    {
      "name": "al-dente",
      "source": "./.agent-plugin",
      "description": "Personal assistant for the Readpeak vault, backed by Pasta."
    }
  ]
}
```

`~/Obsidian/Readpeak/.agent-plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "al-dente",
  "version": "0.1.0",
  "description": "Personal assistant for the Readpeak vault, backed by Pasta: daily notes and plans, weekly reviews, the LLM wiki, and Pasta search and capture.",
  "author": { "name": "Oscar Henriksson" }
}
```

`~/Obsidian/Readpeak/.agent-plugin/.mcp.json`:

```json
{
  "mcpServers": {
    "pasta-kb": {
      "command": "${HOME}/code/pasta/target/service/release/kb-mcp",
      "args": [],
      "env": { "RUST_LOG": "error" }
    }
  }
}
```

`~/Obsidian/Readpeak/.agent-plugin/README.md`:

````markdown
# al-dente

Personal assistant plugin for this vault: Pasta search (`pasta-kb` MCP),
daily notes and plans, weekly reviews, the LLM wiki, and raw-inbox capture.

Install once per machine:

```
claude plugin marketplace add ~/Obsidian/Readpeak
claude plugin install al-dente@orre-vault
```

Edit skills here, then run `/reload-plugins` (or start a new session).
Run `./check.sh` after changes. The MCP needs the pasta user unit's build
at `~/code/pasta/target/service/release/kb-mcp`.
````

- [ ] **Step 4: Run the check; the manifest failures are gone**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: exit 1, and no `manifest invalid` or `.mcp.json` lines; only skills/links failures remain. If `claude plugin validate` rejects `.agent-plugin` because it has no skills yet, accept that one failure here and confirm it clears in Task 2.

- [ ] **Step 5: Commit (vault)**

```bash
cd ~/Obsidian/Readpeak
git status --short .agent-plugin .claude-plugin
git add .claude-plugin/marketplace.json .agent-plugin/.claude-plugin/plugin.json .agent-plugin/.mcp.json .agent-plugin/README.md .agent-plugin/check.sh
git commit -m "feat(al-dente): plugin skeleton, MCP config and check script"
```

---

### Task 2: Move the four vault skills into the plugin

**Files:**
- Move: `~/Obsidian/Readpeak/.claude/skills/{daily-note,daily-plan,llm-wiki,weekly-review}` → `~/Obsidian/Readpeak/.agent-plugin/skills/`
- Modify: each moved `SKILL.md` (vault-root line), `daily-note/SKILL.md:10` (script path)

**Interfaces:**
- Consumes: `check.sh` from Task 1.

- [ ] **Step 1: Confirm the check fails on these skills**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh 2>&1 | grep -E "vault-root|\.claude/skills still exists"`
Expected: `FAIL: daily-note/SKILL.md lacks the vault-root line` (and the other three), and `FAIL: .claude/skills still exists`.

- [ ] **Step 2: Move with history**

```bash
cd ~/Obsidian/Readpeak
mkdir -p .agent-plugin/skills
git mv .claude/skills/daily-note .claude/skills/daily-plan .claude/skills/llm-wiki .claude/skills/weekly-review .agent-plugin/skills/
rmdir .claude/skills
```

- [ ] **Step 3: Add the vault-root line under each H1**

For each of `daily-note daily-plan llm-wiki weekly-review`, insert this line plus a blank line directly after the first `# ` heading in `.agent-plugin/skills/<s>/SKILL.md`:

```
Vault root: `~/Obsidian/Readpeak`. Paths below are relative to it.
```

One way:

```bash
cd ~/Obsidian/Readpeak/.agent-plugin/skills
for s in daily-note daily-plan llm-wiki weekly-review; do
  python3 - "$s/SKILL.md" <<'EOF'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
i = next(n for n, l in enumerate(lines) if l.startswith("# "))
lines[i + 1:i + 1] = ["", "Vault root: `~/Obsidian/Readpeak`. Paths below are relative to it."]
open(p, "w").write("\n".join(lines))
EOF
done
```

- [ ] **Step 4: Fix the daily-note script path**

In `.agent-plugin/skills/daily-note/SKILL.md`, replace
`~/Obsidian/Readpeak/.claude/skills/daily-note/scripts/daily_note.py`
with
`~/Obsidian/Readpeak/.agent-plugin/skills/daily-note/scripts/daily_note.py`.

Then: `python3 ~/Obsidian/Readpeak/.agent-plugin/skills/daily-note/scripts/daily_note.py` (preview only, no `--write`)
Expected: prints the sections it would add; exit 0.

- [ ] **Step 5: Run the check**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: exit 1; no `vault-root`, `.claude/skills` or `manifest invalid` lines. Remaining: skills list (missing the pasta skills and readpeak-assistant) and links.

- [ ] **Step 6: Commit (vault)**

```bash
cd ~/Obsidian/Readpeak
git status --short .agent-plugin .claude/skills
git add .agent-plugin/skills .claude/skills
git commit -m "refactor(al-dente): move vault skills into the plugin"
```

---

### Task 3: Pasta skills and the readpeak-assistant skill

**Files:**
- Create: `~/Obsidian/Readpeak/.agent-plugin/skills/{pasta-vault,personal-agent,raw-inbox-memory}/` (copied from `~/.config/home-manager/nixos/pasta-skills/`)
- Create: `~/Obsidian/Readpeak/.agent-plugin/skills/readpeak-assistant/SKILL.md`

- [ ] **Step 1: Confirm the check fails on them**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh 2>&1 | grep -E "skills are|readpeak-assistant"`
Expected: `FAIL: skills are 'daily-note daily-plan llm-wiki weekly-review', want '…'`, and the readpeak-assistant vault-root and description failures.

- [ ] **Step 2: Copy the pasta skills**

```bash
cp -r ~/.config/home-manager/nixos/pasta-skills/pasta-vault \
      ~/.config/home-manager/nixos/pasta-skills/personal-agent \
      ~/.config/home-manager/nixos/pasta-skills/raw-inbox-memory \
      ~/Obsidian/Readpeak/.agent-plugin/skills/
```

They find the vault through `~/.pasta/config.toml`, so they need no path edits.

- [ ] **Step 3: Write readpeak-assistant**

`~/Obsidian/Readpeak/.agent-plugin/skills/readpeak-assistant/SKILL.md`:

```markdown
---
name: readpeak-assistant
description: Working rules for Oscar's Readpeak vault assistant. Use when the task involves the Readpeak vault, today's plan or daily note, ops/DevOps status, incidents and monitoring, pipelines/deployments/reviews tracked in the vault, or looking up prior context in Pasta. Not for ordinary coding tasks in other repos.
---

# Readpeak assistant

Vault root: `~/Obsidian/Readpeak`. Paths below are relative to it.
Source of truth: `~/Obsidian/Readpeak/AGENTS.md`; if it disagrees with this skill, follow it.
The AWS / production approval gate lives in the global CLAUDE.md and always applies.

## Start from current evidence

- Today's plan: use the `daily-plan` skill. It reads `Templates/Daily-Focus.md`, the dated note under `0. Inbox/Daily/`, `Tasks/`, `1. Projects/`, and recent `.feeds/`. Recommend at most three concrete next actions; keep the OPS-287 checklist.
- Incidents and monitoring: read `2. Areas/Monitoring/Production Monitoring.md` and the relevant project or task note. Distinguish an alert from a verified incident; say what was checked and what is unknown.
- Pipelines, deployments, reviews: the matching project/task note plus current GitLab or CI evidence. Old task tags and feed items are leads, not current status.
- Search Pasta (`pasta-kb` MCP) when prior context would change the answer. If it is unavailable, use the vault and say which facts were not verified live.

## Keep the system organized

- Record durable user-stated decisions, preferences, corrections and commitments verbatim with `raw-inbox-memory`: one small statement, never credentials.
- Edit a canonical task, project, area or daily note only when asked. Preserve the user's writing, links and unrelated work. `1. Projects/` active outcomes, `2. Areas/` ongoing responsibilities, `3. Resources/` reference, `4. Archive/` inactive.
- Use `vault.py` only for the evidence-cited wiki (`llm-wiki` skill). Ordinary notes are edited directly. A saved raw capture is searchable only after Pasta syncs.

## Finish

End with what changed, the evidence for it, and the next concrete action or blocker.
```

- [ ] **Step 4: Run the check**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: exit 1 with only `.agents/skills` link failures left.

- [ ] **Step 5: Commit (vault)**

```bash
cd ~/Obsidian/Readpeak
git status --short .agent-plugin
git add .agent-plugin/skills/pasta-vault .agent-plugin/skills/personal-agent .agent-plugin/skills/raw-inbox-memory .agent-plugin/skills/readpeak-assistant
git commit -m "feat(al-dente): add Pasta skills and readpeak-assistant"
```

---

### Task 4: Codex links

**Files:**
- Modify: `~/Obsidian/Readpeak/.agents/skills/` (symlinks)

- [ ] **Step 1: Confirm the check fails on links**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: `FAIL: .agents/skills is 'daily-plan llm-wiki weekly-review', want '…'` and `FAIL: broken Codex links: …` (the old links point at the removed `.claude/skills`).

- [ ] **Step 2: Replace the links**

```bash
cd ~/Obsidian/Readpeak/.agents/skills
for s in daily-note daily-plan llm-wiki pasta-vault personal-agent raw-inbox-memory readpeak-assistant weekly-review; do
  ln -sfn "../../.agent-plugin/skills/$s" "$s"
done
```

- [ ] **Step 3: Run the check**

Run: `~/Obsidian/Readpeak/.agent-plugin/check.sh`
Expected: `al-dente: all checks passed`, exit 0.

- [ ] **Step 4: Commit (vault)**

```bash
cd ~/Obsidian/Readpeak
git status --short .agents
git add .agents/skills
git commit -m "chore(al-dente): point Codex skill links at the plugin"
```

---

### Task 5: Remove the dead pasta-skills module (home-manager repo)

**Files:**
- Delete: `~/.config/home-manager/nixos/pasta-skills.nix`, `~/.config/home-manager/nixos/pasta-skills/`
- Modify: `docs/superpowers/specs/2026-10-09-al-dente-plugin-design.md` ("Path fixes in moved skills" section)

- [ ] **Step 1: Confirm it is dead and the test is red**

Run: `cd ~/.config/home-manager && git grep -n 'pasta-skills' -- ':!docs'`
Expected: only `nixos/pasta-skills.nix:4` (self-reference) and files under `nixos/pasta-skills/`; no importer. This grep is the test: it must return nothing after Step 2.

- [ ] **Step 2: Delete**

```bash
cd ~/.config/home-manager
git rm -r -q nixos/pasta-skills.nix nixos/pasta-skills
```

- [ ] **Step 3: Update the spec's path-fix section**

Replace the body of "### Path fixes in moved skills" with:

```markdown
Each vault skill gets one line under its H1:
``Vault root: `~/Obsidian/Readpeak`. Paths below are relative to it.``
(decided while planning: the skills hold dozens of vault-relative paths;
one line has the same effect). Eval fixtures under `evals/` keep relative
paths. `daily-note`'s script path changes from `.claude/skills/daily-note/scripts/`
to `.agent-plugin/skills/daily-note/scripts/`.
```

- [ ] **Step 4: Verify**

Run: `git grep -n 'pasta-skills' -- ':!docs'` → no output.
Run: `nix flake check` → passes (needs free disk; see todo.md health row).

- [ ] **Step 5: Commit (home-manager)**

```bash
git add docs/superpowers/specs/2026-10-09-al-dente-plugin-design.md
git commit -m "chore: drop dead pasta-skills module, now in the al-dente plugin"
```

---

### Task 6: Install, global rule, cleanup and smoke test (this laptop)

**Files:**
- Modify: `~/.claude/CLAUDE.md` (one line after the kb rule, line 137)
- Delete (user runs; the permission classifier blocks the agent): `~/.claude/skills/{personal-agent,raw-inbox-memory}`, `~/.codex/skills/{personal-agent,raw-inbox-memory}`

- [ ] **Step 1: Add the AWS gate to the global CLAUDE.md**

Insert after the line starting `kb (from ~/code/pasta):`:

```
Before any AWS command or API call, or any production database change, show the exact operation, account/profile, region and read/change scope, and wait for explicit approval.
```

Verify: `grep -c 'Before any AWS command' ~/.claude/CLAUDE.md` → `1`.

- [ ] **Step 2: Remove the stale skill copies (user)**

```
! rm -rf ~/.claude/skills/personal-agent ~/.claude/skills/raw-inbox-memory ~/.codex/skills/personal-agent ~/.codex/skills/raw-inbox-memory
```

Verify: `ls ~/.claude/skills ~/.codex/skills | grep -E 'personal-agent|raw-inbox-memory'` → no output.

- [ ] **Step 3: Install the plugin**

```
claude plugin marketplace add ~/Obsidian/Readpeak
claude plugin install al-dente@orre-vault
```

Verify: `jq '.enabledPlugins["al-dente@orre-vault"]' ~/.claude/settings.json` → `true`.

- [ ] **Step 4: Smoke test outside the vault**

```bash
cd /tmp && claude plugin list | grep al-dente
cd /tmp && claude mcp list 2>&1 | grep pasta-kb
```

Expected: `al-dente@orre-vault` listed as enabled; `pasta-kb` connected. If `${HOME}` is not expanded in the command (MCP fails with ENOENT on a literal `${HOME}`), change `.agent-plugin/.mcp.json` to the absolute path `/home/orre/code/pasta/target/service/release/kb-mcp`, re-run, and commit that in the vault as `fix(al-dente): absolute kb-mcp path`.

- [ ] **Step 5: Skill smoke test in another repo**

Start `claude` in `~/code/readpeak/mononode`, run `/al-dente:daily-plan`.
Expected: the skill loads and reads `~/Obsidian/Readpeak/0. Inbox/Daily/<today>.md` (or reports it missing without generating it, per the skill).

- [ ] **Step 6: Record the MCP-down behaviour**

While pasta rebuilds next (or with `kb-mcp` temporarily unavailable), `claude mcp list` shows `pasta-kb` failed and `/al-dente:daily-plan` still answers from vault files. Note the result in the plugin README if it differs.

No commit for this task beyond the possible vault fix in Step 4; `~/.claude/CLAUDE.md` and `settings.json` are not in a repo.
