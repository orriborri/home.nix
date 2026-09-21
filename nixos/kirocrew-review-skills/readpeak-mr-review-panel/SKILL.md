---
name: readpeak-mr-review-panel
description: Four-lens parallel review crew for readpeak GitLab MRs — design+correctness (Sage), blast-radius (code-review-graph), security, and documentation (wiki + repo docs + SKILLs + vault + knowledge base). Runs read-only sub-agents over the captured diff, synthesizes in the parent, drafts findings in the user's casual tone. Draft-only, never auto-posts. Use when reviewing an MR in readpeak/{cdk,cloudformation,eks-workloads,mononode,nativeflow}.
version: 1.1.0
tags: [code-review, readpeak, mr-review, sage, code-review-graph, documentation, security]
---

# Readpeak MR Review Panel

A multi-perspective review crew for a single readpeak MR. Four lenses run as
PARALLEL read-only sub-agents over the SAME captured diff (passed inline as
text), then the PARENT synthesizes, cross-checks against the real diff, writes a
Sage result record, and drafts comments. **DRAFT-ONLY — never auto-post to
GitLab.** One MR per clean run.

## Hard rules (from standing lessons)

- **glab / code-review-graph / knowledge-base / filesystem calls run in the
  PARENT**, never in a sub-agent — headless sub-agents don't get interactive
  glab/shell approval and stall. Sub-agents receive the diff (and doc excerpts)
  as INLINE TEXT and do pure read-only reasoning.
- **Verify against the branch bytes**, not a stale checkout — fetch changed files
  via `glab api ... repository/files/<path>/raw?ref=<branch>` when in doubt.
- **Comments in the user's tone**: short, casual, direct — "We should…",
  "Could we…?", "Same with…". No severity/category headings unless the issue
  needs detailed evidence.
- **Draft-only**: findings are staged; a human publishes.

## Repos & paths

| Repo | Checkout | Graph indexed |
|------|----------|---------------|
| cdk | `/var/lib/code/readpeak/cdk` | yes (healthy) |
| cloudformation | `/var/lib/code/readpeak/cloudformation` | rebuild before use |
| eks-workloads | `/var/lib/code/readpeak/eks-workloads` | thin — rebuild before use |
| mononode | `/var/lib/code/readpeak/mononode` | yes |
| nativeflow | `/var/lib/code/readpeak/nativeflow` | yes |

Doc sources: wiki `/var/lib/code/readpeak/wiki` (93 pages), each repo's `docs/`,
in-repo `*.md` and `SKILL.md`, vault `/var/lib/vault`, and the knowledge base
(`local_knowledge_search`).

## Procedure

### 1. Capture the diff (parent)

```bash
glab mr diff <IID> --repo readpeak/<repo>            # full diff
glab api projects/readpeak%2F<repo>/merge_requests/<IID>/changes  # file list + metadata
```
Record: MR IID, source branch, target branch, changed file paths, changed
symbols (function/class/construct names from `+`/`-` hunks). This changed-symbol
+ changed-path set is the SCOPE for lenses 2 and 4 — never grep the whole tree.

### 2. Prepare graph impact (parent)

```bash
code-review-graph status --repo /var/lib/code/readpeak/<repo>   # freshness
# if stale/empty:
code-review-graph update --repo /var/lib/code/readpeak/<repo> --brief
code-review-graph impact --repo /var/lib/code/readpeak/<repo> --files <changed files>
```
Capture: fan-in per changed symbol, cross-community edges, dead-code hits,
architectural warnings. Keep the raw impact output — it feeds lens 2's agent as
text AND informs Sage's `criticality`.

### 3. Prepare doc context (parent) — SCOPED, not whole-tree

For each changed symbol/path, grep the doc corpus for references:

```bash
# wiki + repo docs + in-repo markdown + SKILLs, scoped to changed terms
grep -rniE '<sym1>|<sym2>|<changed-basename>' \
  /var/lib/code/readpeak/wiki \
  /var/lib/code/readpeak/<repo>/docs \
  --include='*.md' -l
# in-repo SKILL.md and READMEs touching the area
```
Also: `local_knowledge_search` for the KB, and grep `/var/lib/vault` for a
documented design of the touched component. Collect the matching doc EXCERPTS
(not whole files) as text for lens 4's agent.

### 4. Fan out four read-only sub-agents — REGISTERED CREWS, CROSS-VENDOR (Claude + GPT)

Each gets the diff inline + its lens-specific context. All read-only reasoning.

**Dispatch the four registered review CREWS, not ad-hoc model spawns.** Each lens is a
crew agent whose spec pins the lens prompt AND an ENFORCED read-only tool set
(`fs_read, code, grep, glob, @kirocrew-core` — no `fs_write`, no `execute_bash`, no
glab/graph/KB). Spawning `agent=<crew>` launches kiro-cli `--agent <crew>`, which loads
that spec and converts its `allowedTools` into a KAS inline permissions policy — so the
read-only contract is enforced by the backend, not merely by the prompt. This is
stronger than a bare `model=` spawn (where read-only is prompt-only and a trust-all
session could let a member write or exec).

**Still one `spawn_run` PER lens, each with its own `model=`.** `spawn_run`'s `model`
applies to the WHOLE call, so this is **four separate `spawn_run` calls** — NOT one call
with a `tasks` array. Pass BOTH `agent=` (the crew, for prompt + enforced tools) and
`model=` (to pin the vendor); `model=` overrides the crew's default model, so vendor
diversity is preserved even though several crews default to `auto`/a shared model. Fire
all four in the same turn, then end the turn. Keep a private map of
`subagent id → (crew, model)` so the synthesis can label each lens.

Roster (verify handles are live with `kiro-cli chat --list-models` before a run — the
catalog changes; keep a same-vendor fallback per slot):

| Lens | `agent=` (crew) | `model=` | Vendor | Fallback model |
|------|-----------------|----------|--------|----------------|
| 1 Design + correctness | `review-design-sage` | `claude-opus-5` | Anthropic | `claude-sonnet-5` |
| 2 Blast-radius / impact | `review-blast-radius` | `gpt-5.6-terra` | OpenAI GPT | `gpt-5.6-luna` |
| 3 Security threat-chains | `review-security` | `claude-sonnet-5` | Anthropic | `claude-sonnet-4.6` |
| 4 Documentation | `review-docs` | `gpt-5.6-luna` | OpenAI GPT | `gpt-5.6-terra` |

Diversity is the point: keep the two Anthropic lenses and the two GPT lenses split
exactly as above rather than collapsing to one vendor. On each spawn pass
`include_memory=false` (the crew prompt is self-contained; inherited memory re-imports
the parent's framing) and `include_lessons=true` (the reviewer conventions live there);
keep `include_project=true`. The parent/Chairman synthesis (step 5) stays on the
session's own model — do not pin it.

The `task` you pass each crew is the DIFF + that lens's context inline (the crew's spec
already carries its lens instructions, so the task is data, not a re-statement of the
role). If a crew name is ever REFUSED (spawn governance), fall back to a bare
`model=`-only spawn for that lens using the lens summary below, and note in the
synthesis that the lens ran unenforced.

1. **Design + correctness (Sage core)** — `agent=review-design-sage`, `model=claude-opus-5`.
   The crew applies `sage-review` (the 10 dimensions, chain-of-consequences,
   self-critique) AND the readpeak rule pack (`readpeak-mr-review-panel/rulepack/SKILL.md`).
   Emit findings + phase1 design verdict.
2. **Blast-radius / impact** — `agent=review-blast-radius`, `model=gpt-5.6-terra`. Given
   the graph impact output + diff: which changed symbols have high fan-in, cross-boundary
   edges, or callers the MR didn't touch? Deletions still referenced elsewhere?
   Architectural seam violations?
3. **Security** — `agent=review-security`, `model=claude-sonnet-5`. Threat chains only
   (attacker input → boundary → mechanism → impact): IAM scoping, `Resource: *`, secret
   exposure/`CfnOutput`, auth fail-open, SSRF, KEDA identity scope. Apply the rule
   pack's security items.
4. **Documentation** — `agent=review-docs`, `model=gpt-5.6-luna`. Given the scoped doc excerpts: (a) does
   the change CONTRADICT a documented design (wiki/docs/vault/KB)? (b) does it leave a
   doc STALE (touches something a doc describes, MR doesn't update the doc)? (c) name
   the authoritative doc the human reviewer should cite. Bidirectional.

Then **END THE TURN** and wait for all four completion events.

### 5. Synthesize (parent, after all events)

- Merge + dedupe findings across lenses (same root issue flagged twice → one
  finding, strongest chain). Ship decision keys on 🔴 only. **A finding raised
  INDEPENDENTLY by both a Claude lens and a GPT lens is a stronger signal — note the
  cross-vendor agreement; a finding only one vendor raised gets an extra skeptical
  cross-check against the diff before it becomes a must-fix.**
- **Cross-check every claim against the real diff** — sub-agents miss deletions
  and misread file status. Verify deletions with `git diff`/`glab` + grep for
  remaining references.
- Verdict block: Design PASS/CONCERNS/FAIL · 🔴 Must-Fix · 🟡 Should-Fix ·
  ✅ clean dimensions.

### 6. Record + draft (parent)

- Write the Sage result record JSON to
  `~/.kiro/crew/apps/code-review-sage/data/results/GL-readpeak-<repo>-<IID>.json`
  (schema `code-review-sage-result`; include `files_covered`, `coverage_complete`,
  a `lenses` array noting graph/doc/security coverage).
- Draft comments in the user's casual tone. DRAFT-ONLY. Present the review in
  chat; let the human choose what posts.

## Gotchas (inherited from cdk-deep-review)

- Graph agents false-negative on deletions — always verify removals against the
  actual diff, not agent claims.
- Doc corpus is large (mononode 295 md). SCOPE the grep to changed symbols/paths;
  never grep the whole tree per MR.
- cloudformation/eks-workloads graph indexes need a rebuild before lens 2 is
  trustworthy.
