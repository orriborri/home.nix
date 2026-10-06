# Shared crew-registration step for the activation scripts that provision
# KiroCrew agent specs (kirocrew-review-agents, kirocrew-dev-crew,
# kirocrew-assistant).
#
# Registration lives in the gateway's mutable config.json, which Nix cannot
# template, so activation asserts it by running the agent CLI as `kirocrew`.
# `agent create` errors if the crew exists, so names `agent list` already
# reports are skipped. The CLI autodetects a project dir from CWD and reads
# $HOME, so it runs from a readable dir with HOME/KIROCREW_HOME set (else it
# dies probing /root/skills). Best-effort: a hung or failing CLI must not wedge
# `nixos-rebuild switch`, hence `timeout 60` and no `set -e` on a single failure.
{ pkgs }:
{
  label,
  names,
  kirocrewHome,
  crewHome,
  kirocrewBin,
  kirocrewLibraryPath,
  skippedNote,
}:
''
  if [ -x "${kirocrewBin}" ]; then
    kc() {
      ${pkgs.sudo}/bin/sudo -u kirocrew -H env \
        HOME="${kirocrewHome}" KIROCREW_HOME="${crewHome}" \
        LD_LIBRARY_PATH="${kirocrewLibraryPath}" \
        ${pkgs.bash}/bin/bash -c "cd ${kirocrewHome} && exec ${pkgs.coreutils}/bin/timeout 60 ${kirocrewBin} \"\$@\"" kc "$@"
    }
    existing="$(kc agent list 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR>1 {print $1}' | ${pkgs.gnused}/bin/sed 's/[* ]*$//')" || existing=""
    for agent_name in ${names}; do
      if printf '%s\n' "$existing" | ${pkgs.gnugrep}/bin/grep -qx "$agent_name"; then
        echo "${label}: crew '$agent_name' already registered, skipping"
      else
        if kc agent create --name "$agent_name" --kiro-agent "$agent_name"; then
          echo "${label}: registered crew '$agent_name'"
        else
          echo "${label}: WARNING failed to register crew '$agent_name'" >&2
        fi
      fi
    done
  else
    echo "${label}: ${kirocrewBin} not built yet; ${skippedNote}" >&2
  fi
''
