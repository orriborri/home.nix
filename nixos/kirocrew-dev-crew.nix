{
  config,
  lib,
  pkgs,
  ...
}:

# HEADLESS provisioning of the AUTHORING tiers of a development pipeline:
#
#   architect  (high model)  → plans
#   implementor(cheap model) → builds from the plan
#   test-writer(cheap model) → writes tests for what was built
#   [review]                 → REUSES the existing MR-review panel defined in
#                              kirocrew-review-agents.nix (design-sage,
#                              blast-radius, security, docs, council-gpt). This
#                              module does NOT define its own reviewer — see the
#                              REVIEW STAGE note below. On a below-APPROVE
#                              verdict the pipeline loops back to the coders.
#
# WHERE THE SPECS LIVE: ../kirocrew-agent-specs.nix is the single source of
# truth for every crew's model, tools, and prompt. This module only PROVISIONS
# the devCrew subset for the headless host (paths under /var/lib/kirocrew, owner
# kirocrew:kirocrew). The workstation provisions the SAME specs from the same
# file via kirocrew-agents-workstation.nix, so the two hosts cannot drift.
#
# The point of the tiering is cost/quality: the expensive model is spent on the
# hard judgement — design (architect) and, in the reused panel, the review
# lenses — while the cheaper model does the mechanical build and test-writing.
#
# REVIEW STAGE — REUSE, DON'T REDEFINE:
#   The review step is the existing read-only panel in kirocrew-review-agents.nix.
#   Those lenses are DRAFT-only and deliberately emit no verdict line, so the
#   loop can't gate on a lens directly. Drive review one of two ways:
#     (a) Chair synthesis (recommended): the PARENT session runs the panel
#         lenses, reconciles their drafts, and emits the single gating line
#         `VERDICT: APPROVE|CONCERNS|FAIL` itself. orchestrate_subagent's
#         `repeat.stopCondition.containsText = "VERDICT: APPROVE"` then loops the
#         coders until the chair approves. This matches the panel's existing
#         "parent runs side-effecting tools, sub-agents reason read-only" rule.
#     (b) Council chair: use `review-council-gpt` as the whole-diff reviewer and
#         have the parent stamp the verdict line from its APPROVE/REQUEST-CHANGES
#         output.
#   Either way the lenses' findings are what feed back to implementor and
#   test-writer on the next iteration.
#
# HOW THE PIPELINE IS DRIVEN (orchestrate_subagent, not Nix):
#   The specs only define the crews and bake in each one's model. The pipeline
#   shape lives in the orchestrate_subagent call. NOTE: orchestrate_subagent's
#   `role` picks a NAMED agent and takes its model FROM the agent definition —
#   there is no per-call model override — so the tiering MUST live in the specs.
#   A run looks like:
#
#     stages:
#       - name: architect     role: architect
#       - name: build         role: implementor   depends_on: [architect]
#       - name: tests         role: test-writer   depends_on: [architect, build]
#       # review stage = the reused panel from kirocrew-review-agents.nix, run
#       # by the chair (parent) which stamps the VERDICT line — see REVIEW STAGE.
#     repeat:
#       maxIterations: 3
#       stopCondition: { containsText: "VERDICT: APPROVE" }
#
#   The review→coders LOOP is the `repeat` block: the chair emits a machine
#   -greppable verdict line from the reused review panel, and orchestrate_subagent
#   re-runs the pipeline until it says APPROVE (or the iteration cap is hit).
#   Each new iteration passes the previous iteration's output — crucially the
#   review findings — back to the first-wave stages as context, so the coders
#   act on the review.
#
# Provisioning mirrors kirocrew-assistant.nix precisely: render each spec to a
# store file, install it into the gateway's Kiro agent dir, then register it as
# a crew idempotently (guarded by `agent list`). Crew registration lives in the
# gateway's mutable config.json (NOT nix-managed), so the script re-asserts it.
let
  kirocrewHome = "/var/lib/kirocrew";
  agentsDir = "${kirocrewHome}/.kiro/agents";
  crewHome = "${kirocrewHome}/.kiro/crew";
  kirocrewBin = "${kirocrewHome}/.kiro/crew-venv/bin/kirocrew";
  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  # Shared spec definitions, wired to this host's gateway binary and crew home.
  agents =
    (import ../kirocrew-agent-specs.nix { inherit lib; } {
      inherit kirocrewBin crewHome;
    }).devCrew;

  # Render each agent to a Nix store JSON file. builtins.toJSON validates the
  # structure at build time, so a malformed spec fails the build rather than
  # landing broken on the box.
  agentFiles = lib.mapAttrs (
    name: spec: pkgs.writeText "kirocrew-agent-${name}.json" (builtins.toJSON spec)
  ) agents;

  installLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: file: ''install -m 0644 -o kirocrew -g kirocrew ${file} "${agentsDir}/${name}.json"''
    ) agentFiles
  );

  registerCrews = import ./kirocrew-register.nix { inherit pkgs; };

  agentNames = lib.concatStringsSep " " (lib.attrNames agents);
in
{
  system.activationScripts.kirocrew-dev-crew = lib.stringAfter [ "users" ] ''
    if id kirocrew >/dev/null 2>&1 && [ -d "${kirocrewHome}/.kiro" ]; then
      install -d -m 0755 -o kirocrew -g kirocrew "${agentsDir}"

      # ── Layer 1: write the agent spec files (declarative source of truth) ──
      ${installLines}

      # ── Layer 2: register each as a crew, idempotently ─────────────────────
      ${registerCrews {
        label = "kirocrew-dev-crew";
        names = agentNames;
        inherit
          kirocrewHome
          crewHome
          kirocrewBin
          kirocrewLibraryPath
          ;
        skippedNote = "wrote specs, skipped registration";
      }}
    fi
  '';
}
