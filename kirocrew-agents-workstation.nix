{
  config,
  lib,
  pkgs,
  ...
}:

# WORKSTATION provisioning of the declarative KiroCrew crews.
#
# The headless EC2 host provisions these same crews through NixOS activation
# scripts (nixos/kirocrew-dev-crew.nix, -review-agents.nix, -assistant.nix)
# writing into /var/lib/kirocrew as the dedicated `kirocrew` user. This module
# is the workstation counterpart: it provisions the SAME specs, from the SAME
# source file (./kirocrew-agent-specs.nix), into the operator's own ~/.kiro tree
# so local and remote cannot drift.
#
# WHAT LANDS HERE:
#   devCrew      architect / implementor / test-writer  (tiered dev pipeline)
#   reviewPanel  review-design-sage / -blast-radius / -security / -docs /
#                -council-gpt                          (read-only MR review)
#   assistant    assistant                             (interactive RW)
#
# TWO LAYERS, ONE IDEMPOTENT SCRIPT — mirrors the NixOS modules:
#   1. Agent SPEC files -> ~/.kiro/agents/<name>.json. Fully declarative: the
#      shared spec file is the source of truth and this overwrites on activation.
#   2. Crew REGISTRATION -> the gateway records "which agent is a crew" in its
#      MUTABLE config at $KIROCREW_HOME/config.json, which Nix cannot template.
#      So the script runs `kirocrew agent create` once per agent, guarded by
#      `agent list` so a re-run on an already-registered crew is a no-op.
#
# WHY home.activation AND NOT home.file:
#   ~/.kiro/agents also holds agents the gateway itself installs (kirocrew.json,
#   kirocrew-conductor.json, the builtin lenses...). home.file would make the
#   whole directory Nix-managed and fight the gateway over those files. Writing
#   only our own specs, by name, leaves the gateway's files alone.
#
# PATHS DIFFER FROM THE HEADLESS HOST — the user service runs the gateway from
# the operator's PATH with KIROCREW_HOME=~/.kiro/crew (see kirocrew-service.nix
# Environment=), so the @kirocrew-core MCP wiring inside each spec must point at
# those, not at /var/lib/kirocrew. That is exactly what the spec file's
# kirocrewBin/crewHome parameters are for.
let
  cfg = config.kirocrew;

  home = config.home.homeDirectory;
  agentsDir = "${home}/.kiro/agents";
  crewHome = "${home}/.kiro/crew";
  # Matches kirocrewExecutable in kirocrew-service.nix for the workstation role
  # (the non-source-install branch): the pipx/source symlink on the operator's
  # PATH. Kept literal rather than derived so this module stays independent of
  # that module's internals.
  kirocrewBin = "${home}/.local/bin/kirocrew";

  # Shared spec definitions — the single source of truth, wired to this host.
  specs = import ./kirocrew-agent-specs.nix { inherit lib; } {
    inherit kirocrewBin crewHome;
  };

  agents = specs.all;

  # Render each spec to a Nix store JSON file. builtins.toJSON validates the
  # structure at build time, so a malformed spec fails the build rather than
  # landing broken in the agents dir.
  agentFiles = lib.mapAttrs (
    name: spec: pkgs.writeText "kirocrew-agent-${name}.json" (builtins.toJSON spec)
  ) agents;

  # install(1) is atomic per file and sets the mode in one step.
  installLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: file: ''$DRY_RUN_CMD install -m 0644 ${file} "${agentsDir}/${name}.json"''
    ) agentFiles
  );

  agentNames = lib.concatStringsSep " " (lib.attrNames agents);
in
{
  # Only on the workstation role. The headless host provisions these through
  # its NixOS activation scripts as the `kirocrew` system user instead.
  home.activation.kirocrewAgents = lib.mkIf (cfg.enable && cfg.role == "workstation") (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # ── Layer 1: write the agent spec files ────────────────────────────────
      $DRY_RUN_CMD mkdir -p "${agentsDir}"
      ${installLines}

      # ── Layer 2: register each as a crew, idempotently ─────────────────────
      # Registration lives in the gateway's MUTABLE config.json, not in Nix, so
      # assert it here. `agent create` errors when the crew already exists, so
      # skip any name `agent list` already reports.
      #
      # Best-effort by design: a registration hiccup (gateway mid-upgrade, venv
      # not built yet) must NOT fail the whole home-manager activation, so every
      # failure is reported and swallowed.
      if [ -x "${kirocrewBin}" ]; then
        kcExisting="$(
          KIROCREW_HOME="${crewHome}" "${kirocrewBin}" agent list 2>/dev/null \
            | ${pkgs.gawk}/bin/awk 'NR>1 {print $1}' \
            | ${pkgs.gnused}/bin/sed 's/[* ]*$//'
        )" || kcExisting=""
        for agent_name in ${agentNames}; do
          if printf '%s\n' "$kcExisting" | ${pkgs.gnugrep}/bin/grep -qx "$agent_name"; then
            $VERBOSE_ECHO "kirocrew-agents: crew '$agent_name' already registered, skipping"
          else
            if $DRY_RUN_CMD env KIROCREW_HOME="${crewHome}" "${kirocrewBin}" \
                 agent create --name "$agent_name" --kiro-agent "$agent_name"; then
              echo "kirocrew-agents: registered crew '$agent_name'"
            else
              echo "kirocrew-agents: WARNING failed to register crew '$agent_name'" >&2
            fi
          fi
        done
      else
        echo "kirocrew-agents: ${kirocrewBin} not present yet; wrote specs, skipped registration" >&2
      fi
    ''
  );
}
