{
  lib,
  pkgs,
  ...
}:

# Declarative agent steering for the KiroCrew gateway.
#
# The default chat agent (and the tiered dev crews) auto-load
# `file://.kiro/steering/**/*.md` as resources (see the rendered specs under
# ~/.kiro/agents/*.json, e.g. assistant.json's `resources`). Anything dropped
# in the gateway user's ~/.kiro/steering is therefore injected into every
# session as standing guidance.
#
# WHY THIS EXISTS: the audit log showed chats repeatedly RECLONING the readpeak
# repos into ad-hoc locations (~/Repos, ~/code/readpeak, /tmp/..., per-MR dirs)
# instead of using the managed checkouts under /var/lib/code/readpeak/<repo>
# that repo-fetch/repo-sync keep current. Recloning wasted disk and repeatedly
# filled the root filesystem. A pre-existing hand-written steering note ("Pull
# workspace.md") hinted at this but was too vague to change behaviour, so this
# module installs an explicit, command-level rule instead. It is versioned in
# the flake (the box's ~/.kiro/steering was previously mutable and unbacked).
#
# Owner/mode mirror the gateway's own state files (kirocrew:kirocrew, 0644 /
# dirs 0755). The gateway reads steering at session start, so dropping the file
# in place (plus the gateway restart the deploy already does) is enough — no
# registration step.
let
  kirocrewHome = "/var/lib/kirocrew";
  steeringDir = "${kirocrewHome}/.kiro/steering";
  src = ./kirocrew-steering;

  files = [
    "reuse-existing-checkouts.md"
  ];

  installLines = lib.concatStringsSep "\n" (
    map (name: ''
      install -m 0644 -o kirocrew -g kirocrew \
        ${src}/${name} "${steeringDir}/${name}"
      echo "kirocrew-steering: installed ${name}"
    '') files
  );
in
{
  system.activationScripts.kirocrew-steering = lib.stringAfter [ "users" ] ''
    if id kirocrew >/dev/null 2>&1 && [ -d "${kirocrewHome}/.kiro" ]; then
      install -d -m 0755 -o kirocrew -g kirocrew "${steeringDir}"
      ${installLines}
    fi
  '';
}
