{
  config,
  lib,
  pkgs,
  ...
}:

# Declarative provisioning of the readpeak code-review skills.
#
# These four skills were previously USER-AUTHORED and lived ONLY on the box, in
# the gateway's mutable skills dir, with no version history and no backup — a
# box rebuild would lose them. This module brings them into the flake as the
# source of truth and installs them on every activation, so they are versioned,
# reproducible, and reviewable.
#
#   readpeak-mr-review-panel  — the four-lens panel driver (+ its rulepack/)
#   council-review            — cross-vendor full-review council
#   sage-review               — the 10-dimension review method
#   mr-logic-review           — pseudocode legibility aid (no verdict)
#
# The panel and council skills dispatch the REGISTERED review crews
# (kirocrew-review-agents.nix) via `spawn_run(agent=<crew>, model=<id>)`. That
# path launches kiro-cli `--agent`, which loads the crew's on-disk spec and
# converts its `allowedTools` into an enforced KAS permissions policy — so each
# lens's read-only contract is enforced by the backend, not merely by prompt.
# `model=` still overrides per-lens to keep the cross-vendor (Claude+GPT) split.
#
# WHY NOT the skill-sync mechanism: sync (kirocrew-skill-sync) installs skills
# from a managed manifest and only removes ones that leave that manifest. These
# skills carry no provenance and are not in any synced repo, so sync ignores
# them; installing them here does not conflict with sync. Owner/mode match the
# gateway's own skills (kirocrew:kirocrew, files 0644, dirs 0755).
#
# The gateway discovers skills from the directory at startup, so no registration
# step is needed — dropping the files in place (and restarting the gateway,
# which the deploy does) is enough.
let
  kirocrewHome = "/var/lib/kirocrew";
  skillsDir = "${kirocrewHome}/.kiro/crew/skills";
  src = ./kirocrew-review-skills;

  # Each skill is a directory copied wholesale from the in-flake source, so a
  # skill with sub-content (the panel's rulepack/) comes along without special
  # casing. Listed explicitly rather than globbed so adding a skill is a
  # deliberate, reviewable change.
  skills = [
    "readpeak-mr-review-panel"
    "council-review"
    "sage-review"
    "mr-logic-review"
  ];

  installLines = lib.concatStringsSep "\n" (
    map (
      name: ''
        # Replace the skill dir atomically-ish: stage from the store, then swap.
        rm -rf "${skillsDir}/.${name}.incoming"
        cp -r ${src}/${name} "${skillsDir}/.${name}.incoming"
        rm -rf "${skillsDir}/${name}"
        mv "${skillsDir}/.${name}.incoming" "${skillsDir}/${name}"
        chown -R kirocrew:kirocrew "${skillsDir}/${name}"
        find "${skillsDir}/${name}" -type d -exec chmod 0755 {} +
        find "${skillsDir}/${name}" -type f -exec chmod 0644 {} +
        echo "kirocrew-review-skills: installed ${name}"''
    ) skills
  );
in
{
  system.activationScripts.kirocrew-review-skills = lib.stringAfter [ "users" ] ''
    if id kirocrew >/dev/null 2>&1 && [ -d "${kirocrewHome}/.kiro/crew" ]; then
      install -d -m 0755 -o kirocrew -g kirocrew "${skillsDir}"
      ${installLines}
    fi
  '';
}
