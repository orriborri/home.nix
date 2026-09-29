{ lib, ... }:

let
  skills = ./pasta-skills;
in
{
  # Copy skill folders instead of symlinking to enable terum-skills inspection
  home.activation.copySkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p $HOME/.claude/skills $HOME/.codex/skills

    for skill in personal-agent raw-inbox-memory pasta-vault; do
      for basedir in .claude .codex; do
        target="$HOME/$basedir/skills/$skill"
        if [ -e "$target" ]; then
          rm -rf "$target"
        fi
        cp -r "${skills}/$skill" "$target"
      done
    done
  '';
}
