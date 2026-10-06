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
  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  # Shared spec definitions (../kirocrew-agent-specs.nix is the single source of
  # truth for every crew's model, tools, allowedTools ceiling, and prompt). This
  # module only PROVISIONS the reviewPanel subset for the headless host; the
  # workstation provisions the SAME specs from the same file, so the two hosts
  # cannot drift.
  agents =
    (import ../kirocrew-agent-specs.nix { inherit lib; } {
      inherit kirocrewBin crewHome;
    }).reviewPanel;

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

  registerCrews = import ./kirocrew-register.nix { inherit pkgs; };

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
    fi
  '';

  # Registration needs the crew-venv symlink the gateway's ExecStartPre creates,
  # so it runs from kirocrew-register-agents (ordered after the gateway), not at
  # activation, which only writes the specs.
  systemd.services.kirocrew-register-agents.serviceConfig.ExecStart = [
    (pkgs.writeShellScript "kirocrew-register-review-agents" (registerCrews {
      label = "kirocrew-review-agents";
      names = agentNames;
      inherit
        kirocrewHome
        crewHome
        kirocrewBin
        kirocrewLibraryPath
        ;
      skippedNote = "skipped registration";
    }))
  ];
}
