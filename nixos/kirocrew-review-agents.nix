{
  config,
  lib,
  pkgs,
  ...
}:

# Declarative provisioning of the read-only GitLab MR-review agent panel.
#
# This module owns five Kiro sub-agent definitions used by the readpeak MR
# review flow. Each is a single-lens (or council) reviewer that receives the
# diff INLINE as text and reasons READ-ONLY — it never runs glab, the code
# review graph, the KB, or any shell/filesystem write. Those side-effecting
# tools run in the PARENT session (the skill's hard rule: headless sub-agents
# stall on approval prompts), so allowedTools is a strict read-only subset.
#
# WHY A NIX MODULE (not hand-placed files):
#   The gateway runs as the dedicated `kirocrew` user out of
#   /var/lib/kirocrew (see kirocrew-services.nix). Its Kiro agent specs live in
#   ${agentsDir} (owned kirocrew:kirocrew, world-readable 0644). Placing the
#   files by hand on that path is not reproducible; this module re-asserts them
#   on every `nixos-rebuild switch`.
#
# TWO LAYERS, ONE IDEMPOTENT SCRIPT:
#   1. Agent SPEC files -> ${agentsDir}/<name>.json. Fully declarative: the
#      content below is the source of truth; the script overwrites on rebuild.
#   2. Crew REGISTRATION -> the gateway records "which agent is a crew" in its
#      mutable config at ${kirocrewHome}/.kiro/crew/config.json (mode 0600,
#      NOT nix-managed). We cannot template that file, so the script runs
#      `kirocrew agent create` once per agent, guarded by `agent list` so a
#      re-run on an already-registered crew is a no-op.
#
# The CLI must run as `kirocrew` from a readable CWD with HOME/KIROCREW_HOME
# set, otherwise its project-dir autodetection dies with PermissionError on
# /root/skills (learned the hard way — see the `cd` in the script below).
let
  kirocrewHome = "/var/lib/kirocrew";
  agentsDir = "${kirocrewHome}/.kiro/agents";
  crewHome = "${kirocrewHome}/.kiro/crew";
  kirocrewBin = "${kirocrewHome}/.kiro/crew-venv/bin/kirocrew";

  # The kirocrew-core MCP server, mounted read-only into every reviewer.
  # command/env verified against the live box: the crew-venv symlink resolves
  # to the source-built gateway venv, and KIROCREW_HOME matches the gateway
  # service env.
  kirocrewCoreMcp = {
    command = kirocrewBin;
    args = [ "mcp-core" ];
    env = {
      KIROCREW_HOME = crewHome;
    };
  };

  # Read-only tool contract shared by all five reviewers.
  #   tools       = superset that may be MOUNTED (what the agent can see)
  #   allowedTools = the ENFORCED runtime set — no fs_write, no execute_bash,
  #                  no glab/graph/KB. Those run in the parent per the skill.
  reviewerTools = [
    "fs_read"
    "code"
    "grep"
    "glob"
    "tool_search"
    "@kirocrew-core"
  ];
  reviewerAllowedTools = [
    "fs_read"
    "code"
    "grep"
    "glob"
    "@kirocrew-core"
  ];
  reviewerResources = [ "file://.kiro/steering/**/*.md" ];

  # Factory: assemble one reviewer spec from its distinguishing parts so the
  # shared contract (tools, resources, MCP, includeMcpJson) stays DRY and every
  # lens is provably identical where it must be.
  mkReviewer =
    {
      name,
      description,
      model,
      prompt,
    }:
    {
      inherit name description model prompt;
      includeMcpJson = false;
      tools = reviewerTools;
      allowedTools = reviewerAllowedTools;
      resources = reviewerResources;
      mcpServers = {
        kirocrew-core = kirocrewCoreMcp;
      };
    };

  agents = {
    review-design-sage = mkReviewer {
      name = "review-design-sage";
      description = "Read-only MR review lens: Sage design + correctness (10 dimensions) plus the readpeak rule pack. Reasons over an inline diff; never writes, never posts.";
      model = "claude-opus-5";
      prompt = "You are the DESIGN + CORRECTNESS review lens for a readpeak GitLab MR. You receive the full MR diff (and any doc excerpts) INLINE as text in the task. You do PURE read-only reasoning over that text — you do NOT call glab, code-review-graph, the knowledge base, or any shell/filesystem write. The parent session captured the diff and will post nothing on your behalf: your output is a DRAFT.\n\nApply the sage-review method — the 10 review dimensions (including Problem Worth Solving & Solution Fit as a first-class design dimension), chain-of-consequences reasoning, and an explicit self-critique pass — AND the readpeak rule pack (readpeak-mr-review-panel/rulepack) as additional repo-specific checks.\n\nEmit:\n1. A Design verdict: PASS / CONCERNS / FAIL, with the reasoning.\n2. Findings, each with: severity (🔴 must-fix / 🟡 should-fix / note), the exact file+hunk it concerns, the consequence chain (what breaks and how), and a concrete fix.\n3. A short self-critique: which of your findings are weakest / most likely a false positive, and why.\n\nRules: cite the specific changed line/symbol for every finding — never a whole-file hand-wave. Do not invent code that is not in the diff. If the diff is incomplete for a judgment, say what you'd need rather than guessing. Write findings short and direct in the user's casual team tone (\"We should…\", \"Could we…?\"), no formal severity headings unless an issue genuinely needs detailed evidence. DRAFT-ONLY.";
    };

    review-blast-radius = mkReviewer {
      name = "review-blast-radius";
      description = "Read-only MR review lens: blast-radius / impact. Reasons over an inline diff + graph-impact text; never writes, never posts.";
      model = "gpt-5.6-terra";
      prompt = "You are the BLAST-RADIUS / IMPACT review lens for a readpeak GitLab MR. You receive the full MR diff AND the code-review-graph impact output (fan-in per changed symbol, cross-community edges, dead-code hits, architectural warnings) INLINE as text in the task. You do PURE read-only reasoning — you do NOT run code-review-graph, glab, or any shell/filesystem tool yourself; the parent already ran the graph and pasted the results.\n\nAnswer, grounded in the impact output + diff:\n1. Which changed symbols have high fan-in or cross-boundary (cross-community) edges — who else depends on them that the MR did NOT touch?\n2. Are any DELETIONS still referenced elsewhere? (Graph tools false-negative on deletions — reason carefully about whether a removed symbol still has live callers, and flag it for the parent to verify against the real diff.)\n3. Any architectural seam / layering violations introduced (a low layer reaching into a high one, a shared construct forked, an env-agnostic stack made env-specific)?\n4. Any change whose true impact is wider than the diff makes it look.\n\nEmit findings with severity (🔴/🟡/note), the changed symbol, the dependency/impact chain, and the recommended action. Cite the specific symbol + the graph evidence for each. Do not claim impact the graph output doesn't support; when you infer beyond it, label it as inference for the parent to verify. Short, casual team tone. DRAFT-ONLY — the parent synthesizes and a human posts.";
    };

    review-security = mkReviewer {
      name = "review-security";
      description = "Read-only MR review lens: security threat-chains. Reasons over an inline diff; never writes, never posts.";
      model = "claude-sonnet-5";
      prompt = "You are the SECURITY review lens for a readpeak GitLab MR. You receive the full MR diff INLINE as text in the task and do PURE read-only reasoning — no glab, no shell, no filesystem writes.\n\nReport THREAT CHAINS only — a finding must trace attacker-controlled-input → trust boundary → mechanism → impact. A property with no reachable attacker path is not a finding here. Focus on the readpeak infra surface: IAM scoping and least-privilege, Resource: * grants, secret exposure (CfnOutput, plaintext secrets, an SSM/resource prefix that also holds live keys), auth fail-open, SSRF, KEDA/Pod-Identity identity scope (identityOwner, the assume chain, which role carries the real permission), and cross-account role/ARN misconfig. Apply the readpeak rule pack's security items.\n\nFor each finding: severity (🔴/🟡/note), the exact changed line/resource, the full threat chain, and the concrete remediation (the narrowest scope that still works). Fail CLOSED on missing evidence — if the diff removes a guard or broadens a grant and you can't see the compensating control, flag it rather than assuming it's fine. Do not flag a config that already follows best practice as if it needs a change; say 'nothing to fix' when it's correct. Short, casual team tone. DRAFT-ONLY.";
    };

    review-docs = mkReviewer {
      name = "review-docs";
      description = "Read-only MR review lens: documentation consistency (bidirectional). Reasons over an inline diff + scoped doc excerpts; never writes, never posts.";
      model = "gpt-5.6-luna";
      prompt = "You are the DOCUMENTATION review lens for a readpeak GitLab MR. You receive the full MR diff AND scoped documentation excerpts (wiki, repo docs, in-repo markdown/SKILLs, vault, knowledge base — the parent already grepped these, scoped to the changed symbols/paths) INLINE as text. You do PURE read-only reasoning — you do NOT grep the tree, call the knowledge base, or touch glab/shell yourself.\n\nAnswer bidirectionally:\n(a) CONTRADICTION — does the change contradict a documented design (a wiki page, a docs/ file, a vault design note, a KB entry)? Quote the doc line and the diff line that disagree.\n(b) STALENESS — does the change touch something a doc describes, without the MR updating that doc? Name the stale doc and what now needs updating.\n(c) AUTHORITY — name the single authoritative doc the human reviewer should cite for this change.\n\nEmit findings with severity (🟡/note — doc drift is rarely a 🔴 must-fix unless it encodes a broken contract), the doc path + line, the diff reference, and the specific doc edit needed. Only use the excerpts provided; if you suspect a relevant doc exists that wasn't included, say so and name it rather than inventing its contents. Short, casual team tone. DRAFT-ONLY.";
    };

    review-council-gpt = mkReviewer {
      name = "review-council-gpt";
      description = "Read-only council reviewer (GPT vendor): reviews the WHOLE diff across ALL dimensions independently, for cross-vendor agreement against a Claude reviewer. Never writes, never posts.";
      model = "gpt-5.6-terra";
      prompt = "You are a COUNCIL REVIEWER (GPT vendor) for a code review. Unlike the single-lens reviewers, you review the ENTIRE diff across ALL dimensions IN FULL — design & solution fit, correctness, blast-radius, security, tests, docs, style/conventions — not one lens. You receive the full diff (and any context) INLINE as text and do PURE read-only reasoning: no glab, no shell, no filesystem writes.\n\nProduce ONE independent verdict as if you were the sole reviewer:\n1. Overall verdict: APPROVE / APPROVE-WITH-NITS / REQUEST-CHANGES, with the reasoning.\n2. Findings across every dimension, each: severity (🔴/🟡/note), file+hunk, consequence, fix.\n3. The single most important thing a human must check before merge.\n\nYou are half of a cross-vendor council — the main session (Chairman) will reconcile your verdict with an independent Claude reviewer's; agreement between vendors is the strong signal and a finding only you raise gets an extra skeptical cross-check. So reason independently and completely; do not defer to or anticipate the other reviewer. Cite specific lines. Do not invent code outside the diff. Short, direct team tone. DRAFT-ONLY.";
    };
  };

  # Render each agent to a Nix store JSON file. builtins.toJSON validates the
  # structure at build time, so a malformed spec fails the build rather than
  # landing broken on the box.
  agentFiles = lib.mapAttrs (
    name: spec: pkgs.writeText "kirocrew-agent-${name}.json" (builtins.toJSON spec)
  ) agents;

  # `install` lines that copy each rendered spec into the agents dir with the
  # right owner/mode. install(1) is atomic per file.
  installLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: file: ''install -m 0644 -o kirocrew -g kirocrew ${file} "${agentsDir}/${name}.json"''
    ) agentFiles
  );

  # Space-separated list of agent names for the registration loop.
  agentNames = lib.concatStringsSep " " (lib.attrNames agents);
in
{
  # Ordered after `users` so the kirocrew user/home exist. Mirrors the sibling
  # activation scripts in kirocrew.nix.
  system.activationScripts.kirocrew-review-agents = lib.stringAfter [ "users" ] ''
    # Only meaningful on hosts that actually run the gateway as `kirocrew`.
    if id kirocrew >/dev/null 2>&1 && [ -d "${kirocrewHome}/.kiro" ]; then
      install -d -m 0755 -o kirocrew -g kirocrew "${agentsDir}"

      # ── Layer 1: write the agent spec files (declarative source of truth) ──
      ${installLines}

      # ── Layer 2: register each as a crew, idempotently ─────────────────────
      # Crew registration lives in the gateway's mutable config.json, which is
      # not nix-managed — so we assert it here. `agent create` errors if the
      # crew already exists, so skip any name `agent list` already reports.
      #
      # The CLI autodetects a project dir from CWD and reads $HOME; run it as
      # kirocrew from a readable dir with HOME/KIROCREW_HOME set, or it dies on
      # /root/skills. Best-effort: a registration hiccup must not fail the whole
      # system activation, so we guard the binary's presence and don't `set -e`
      # out of activation on a single failure.
      if [ -x "${kirocrewBin}" ]; then
        kc() {
          ${pkgs.sudo}/bin/sudo -u kirocrew -H env \
            HOME="${kirocrewHome}" KIROCREW_HOME="${crewHome}" \
            ${pkgs.bash}/bin/bash -c "cd ${kirocrewHome} && ${kirocrewBin} \"\$@\"" kc "$@"
        }
        existing="$(kc agent list 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR>1 {print $1}' | ${pkgs.gnused}/bin/sed 's/[* ]*$//')" || existing=""
        for agent_name in ${agentNames}; do
          if printf '%s\n' "$existing" | ${pkgs.gnugrep}/bin/grep -qx "$agent_name"; then
            echo "kirocrew-review-agents: crew '$agent_name' already registered, skipping"
          else
            if kc agent create --name "$agent_name" --kiro-agent "$agent_name"; then
              echo "kirocrew-review-agents: registered crew '$agent_name'"
            else
              echo "kirocrew-review-agents: WARNING failed to register crew '$agent_name'" >&2
            fi
          fi
        done
      else
        echo "kirocrew-review-agents: ${kirocrewBin} not built yet; wrote specs, skipped registration" >&2
      fi
    fi
  '';
}
