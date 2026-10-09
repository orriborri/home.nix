# al-dente: a Claude plugin for the Readpeak vault and Pasta

Date: 2026-10-09. Status: design approved in chat, spec awaiting review.

## Goal

One Claude Code plugin, `al-dente`, that makes the personal assistant
available from any directory: the Pasta knowledge base (via `kb-mcp`), the
vault skills, and the vault's working rules. Success: a fresh session in an
unrelated repo (for example `~/code/readpeak/mononode`) can run
`/al-dente:daily-plan` and search Pasta with no per-directory setup.

Scope is this laptop only. Running it on the EC2 / claude-remote box is a
later step (see "Later").

## Current state (verified 2026-10-09)

| Piece | Location | Visible to Claude |
|---|---|---|
| `kb-mcp` | `~/.mcp.json` (project scope); entries since removed | only in sessions started in `~` |
| `daily-note`, `daily-plan`, `weekly-review`, `llm-wiki` | `~/Obsidian/Readpeak/.claude/skills/` (vault repo `gitlab.com:orriborri/Vault`) | only in the vault |
| `pasta-vault`, `personal-agent`, `raw-inbox-memory` | `nixos/pasta-skills/` in this repo; module `nixos/pasta-skills.nix` is imported nowhere | stale copies of two of them in `~/.claude/skills` and `~/.codex/skills` (Sep 29–30); `pasta-vault` not installed |
| Vault rules | `~/Obsidian/Readpeak/AGENTS.md` | only in the vault |
| kb read-only rule | `~/.claude/CLAUDE.md:137` | every session |

## Decisions

1. **Scope: everywhere, laptop only.** The plugin carries all skills and the
   MCP; skills reach the vault by absolute path.
2. **Source lives in the vault repo.** Four of the seven skills are already
   there; the EC2 box later gets it through the existing KiroCrew vault sync.
   Cost: no Nix checks, and KiroCrew's auto-commits ("KiroCrew vault update")
   may pick up plugin edits.
3. **Rules split.** The AWS / production approval gate becomes an always-on
   line in `~/.claude/CLAUDE.md`. The rest of `AGENTS.md` becomes an
   on-demand skill. An approval gate must not depend on a skill being judged
   relevant.
4. **Names.** Marketplace `orre-vault` (the name `readpeak` is taken by the
   `readpeak/rp-brain` marketplace); plugin `al-dente`; skills are invoked as
   `/al-dente:<skill>`.
5. **MCP command uses `${HOME}` expansion**, which is documented, rather than a
   bare `kb-mcp` PATH lookup, which is not.

## Layout (vault repo)

```
~/Obsidian/Readpeak/
  .claude-plugin/marketplace.json     marketplace "orre-vault"; one plugin, source "./.agent-plugin"
  .agent-plugin/                      plugin root
    .claude-plugin/plugin.json        name "al-dente"
    .mcp.json                         pasta-kb
    README.md                         install commands for a new machine
    skills/
      readpeak-assistant/             new
      daily-note/  daily-plan/  weekly-review/  llm-wiki/        moved from .claude/skills/
      pasta-vault/  personal-agent/  raw-inbox-memory/           moved from home-manager nixos/pasta-skills/
  .agents/skills/*                    Codex symlinks -> ../../.agent-plugin/skills/*
```

The plugin is a subfolder, not the vault root. A local-path marketplace loads
plugins in place, so this does not matter today; a git-hosted marketplace
(the later EC2 case) copies the plugin folder, and that must not be the whole
vault (`.git`, `.lancedb`, attachments).

`.agent-plugin/.mcp.json`:

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

This one entry replaces the old `pasta-kb` and `kb-evidence` entries, which
ran the same binary.

### readpeak-assistant skill

Description triggers on vault, daily planning, ops/DevOps status, incidents,
pipelines and Pasta lookups. Body: the "Start from current evidence" and
"Keep the system organized" sections of `AGENTS.md`, with vault paths made
absolute, and a pointer to `~/Obsidian/Readpeak/AGENTS.md` as the source of
truth. It does not restate the AWS gate (that lives in the global CLAUDE.md).

### Path fixes in moved skills

Paths relative to the vault root become `~/Obsidian/Readpeak/…`, for example
`llm-wiki/SKILL.md:44` (`.llm-wiki/generated/`) and `weekly-review/SKILL.md:32`.
`daily-note`'s script path changes from `.claude/skills/daily-note/scripts/`
to `.agent-plugin/skills/daily-note/scripts/`.

## Install and update

One-time, per machine (also in the plugin README):

```
claude plugin marketplace add ~/Obsidian/Readpeak
claude plugin install al-dente@orre-vault
```

These write `extraKnownMarketplaces` and `enabledPlugins` into
`~/.claude/settings.json`. Claude edits that file itself, so Home Manager does
not own it.

Editing: change files in the vault, then `/reload-plugins` or start a new
session. Local-path plugins load in place; no version bump or
`/plugin update` is needed (code.claude.com/docs/en/plugins/loading.md).

## Migration

Vault repo, one commit (following its `AGENTS.md`: only these files change):

1. Add the marketplace, plugin manifest, `.mcp.json` and README.
2. `git mv .claude/skills/* .agent-plugin/skills/`.
3. Copy the three pasta skills from this repo's `nixos/pasta-skills/`.
4. Add `readpeak-assistant`.
5. Apply the path fixes.
6. Retarget `.agents/skills/*` and add links for the other skills (8 total).

home-manager repo, one commit: delete `nixos/pasta-skills.nix` and
`nixos/pasta-skills/` (dead; the vault owns the skills now).

Global, by the user:

- Remove the stale copies, which would shadow the plugin's skills under the
  same names: `~/.claude/skills/{personal-agent,raw-inbox-memory}` and
  `~/.codex/skills/{personal-agent,raw-inbox-memory}`.
- Add to `~/.claude/CLAUDE.md`, next to the kb rule: "Before any AWS command
  or API call, or any production database change, show the exact operation,
  account/profile, region and read/change scope, and wait for explicit
  approval."
- Run the two install commands.

## Failure modes

- `kb-mcp` missing (for example during a pasta rebuild): the MCP shows as
  failed; the skills still work from the vault files.
- Vault not cloned (new machine): `claude plugin marketplace add` fails
  loudly; nothing is half-installed.
- Pasta target dir moves again: only `.agent-plugin/.mcp.json` changes.

## Verification

| What | Command | Pass when |
|---|---|---|
| Manifests valid | `claude plugin validate ~/Obsidian/Readpeak/.agent-plugin`, and the same on `~/Obsidian/Readpeak` | both exit 0 |
| No vault-relative paths | `grep -rnE '(^\|[ (\x60])\.llm-wiki/\|\.claude/skills' ~/Obsidian/Readpeak/.agent-plugin/skills` | 0 hits |
| Codex links | `find ~/Obsidian/Readpeak/.agents/skills -xtype l` | 0 broken, 8 entries |
| Works outside the vault | in `/tmp`: `claude plugin list`, `claude mcp list` | `al-dente@orre-vault` enabled; pasta-kb connected |
| Skills reachable | fresh session in `~/code/readpeak/mononode`, `/al-dente:daily-plan` | skill loads and reads `~/Obsidian/Readpeak/0. Inbox/Daily/…` |
| home-manager green | `git grep pasta-skills`; `nix flake check` | 0 hits; passes |

The vault is not a Nix repo, so the vault checks are run by hand once at the
end of implementation.

## Later (out of scope)

- EC2 / claude-remote: add the vault's marketplace there via a git source,
  and point the MCP at the box's `kb-mcp`.
- Home Manager-managed install (merge the two settings keys at activation)
  if a second machine appears.
