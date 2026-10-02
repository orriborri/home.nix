{
  config,
  lib,
  pkgs,
  ...
}:

# Declarative provisioning of the personal-assistant crew.
#
# Unlike the read-only MR-review lenses (kirocrew-review-agents.nix), this is an
# INTERACTIVE, READ-WRITE assistant the operator converses with (dashboard or a
# Slack channel). It is NOT a headless sub-agent, so approval prompts are fine —
# the operator is present to approve. It therefore carries the full acting
# toolset, mirroring the shipped `default` (kirocrew) agent's posture.
#
# CAPABILITY WIRING (verified against the live box — see session notes):
#   - kirocrew  -> @kirocrew-core MCP (defined below; command/env match the
#                  gateway service env).
#   - pasta     -> @pasta-kb (gateway-provided namespace; reads the vault + the
#                  Slack/Linear/GitLab history pasta has synced). NOT redefined
#                  here — the gateway resolves it.
#   - Linear    -> @linear (gateway-provided namespace, read-write). NOT
#                  redefined here.
#   - Slack     -> @slack MCP server (kirocrew-services.nix) reusing the shared
#                  sops slack-bot-token; read (history/users) + post
#                  (chat.postMessage). Slack is ALSO a gateway messaging channel
#                  (config slack.tracking_channels / open_channels) that relays
#                  messages to the session — the two are complementary.
#   - GitLab    -> no GitLab MCP exists on the box, so live GitLab actions go
#                  through the `glab` CLI, which needs execute_bash. The operator
#                  approved shell access for this (interactive, approvals gate it).
#   - vault RW  -> fs_read/fs_write over /var/lib/vault (symlinked into the
#                  gateway workspace as `vault`, already in
#                  agent.subagent_cwd_allowed_roots).
#
# Provisioning mirrors kirocrew-review-agents.nix: render the spec to a store
# file, install it into the gateway's Kiro agent dir, then register it as a crew
# idempotently (guarded by `agent list`). Crew registration lives in the
# gateway's mutable config.json (not nix-managed), so the script re-asserts it.
let
  kirocrewHome = "/var/lib/kirocrew";
  agentsDir = "${kirocrewHome}/.kiro/agents";
  crewHome = "${kirocrewHome}/.kiro/crew";
  kirocrewBin = "${kirocrewHome}/.kiro/crew-venv/bin/kirocrew";
  kirocrewLibraryPath = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];

  agentName = "assistant";

  # Shared spec definition (../kirocrew-agent-specs.nix is the single source of
  # truth for every crew's model, tools, and prompt). This module only
  # PROVISIONS the assistant for the headless host; the workstation provisions
  # the SAME spec from the same file, so the two hosts cannot drift.
  assistant =
    (import ../kirocrew-agent-specs.nix { inherit lib; } {
      inherit kirocrewBin crewHome;
    }).assistant.${agentName};


  agentFile = pkgs.writeText "kirocrew-agent-${agentName}.json" (builtins.toJSON assistant);
in
{
  system.activationScripts.kirocrew-assistant = lib.stringAfter [ "users" ] ''
    if id kirocrew >/dev/null 2>&1 && [ -d "${kirocrewHome}/.kiro" ]; then
      install -d -m 0755 -o kirocrew -g kirocrew "${agentsDir}"

      # ── Layer 1: write the agent spec (declarative source of truth) ────────
      install -m 0644 -o kirocrew -g kirocrew ${agentFile} "${agentsDir}/${agentName}.json"

      # ── Layer 2: register as a crew, idempotently ──────────────────────────
      # Registration lives in the gateway's mutable config.json (not nix-managed).
      # `agent create` errors if the crew exists, so skip when already present.
      # Run the CLI as kirocrew from a readable CWD with HOME/KIROCREW_HOME set,
      # else it dies probing /root/skills. Best-effort: never fail activation.
      if [ -x "${kirocrewBin}" ]; then
        kc() {
          ${pkgs.sudo}/bin/sudo -u kirocrew -H env \
            HOME="${kirocrewHome}" KIROCREW_HOME="${crewHome}" \
            LD_LIBRARY_PATH="${kirocrewLibraryPath}" \
            ${pkgs.bash}/bin/bash -c "cd ${kirocrewHome} && ${kirocrewBin} \"\$@\"" kc "$@"
        }
        existing="$(kc agent list 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR>1 {print $1}' | ${pkgs.gnused}/bin/sed 's/[* ]*$//')" || existing=""
        if printf '%s\n' "$existing" | ${pkgs.gnugrep}/bin/grep -qx "${agentName}"; then
          echo "kirocrew-assistant: crew '${agentName}' already registered, skipping"
        else
          if kc agent create --name "${agentName}" --kiro-agent "${agentName}"; then
            echo "kirocrew-assistant: registered crew '${agentName}'"
          else
            echo "kirocrew-assistant: WARNING failed to register crew '${agentName}'" >&2
          fi
        fi
      else
        echo "kirocrew-assistant: ${kirocrewBin} not built yet; wrote spec, skipped registration" >&2
      fi
    fi
  '';
}
