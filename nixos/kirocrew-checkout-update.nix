# `kirocrew-checkout-update MIRROR DESTINATION`: bring one managed checkout
# (kirocrew-code.nix repo-sync) up to date with its mirror. Clones it when
# absent; fast-forwards it when clean; leaves it untouched when it holds
# local work.
#
# Exit: 0 ready or updated, 1 failure, 3 skipped because of local work.
{ pkgs }:
pkgs.writeShellApplication {
  name = "kirocrew-checkout-update";
  runtimeInputs = with pkgs; [
    coreutils
    git
    gnugrep
  ];
  text = ''
    set -uo pipefail
    mirror="$1"
    destination="$2"
    name="$(basename "$destination")"

    if [[ ! -d "$mirror/objects" ]]; then
      echo "Skipping unavailable mirror: $name" >&2
      exit 1
    fi
    if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
      echo "Checkout destination is not a Git repository: $destination" >&2
      exit 1
    fi
    if [[ ! -d "$destination/.git" ]]; then
      mkdir -p "$(dirname "$destination")"
      if ! git clone --config core.sharedRepository=group "$mirror" "$destination"; then
        echo "Checkout clone failed: $name" >&2
        exit 1
      fi
      echo "Ready: $name"
      exit 0
    fi

    git -C "$destination" remote set-url origin "$mirror"
    git -C "$destination" config core.sharedRepository group

    # `code-review-graph install` (kirocrew-code.nix graph sync) appends a
    # block to .gitignore, rewrites .kiro/settings/mcp.json and adds files
    # under .kiro/. Those are not local work: the .gitignore block is dropped
    # (the graph dir ignores itself), mcp.json is set aside and put back after
    # the fast-forward, untracked crg files stay. Anything else is local work.
    crg_gitignore_only() {
      local file="$1" line
      while IFS= read -r line; do
        case "$line" in
          "+" | "+# Added by code-review-graph" | "+.code-review-graph/") ;;
          *) return 1 ;;
        esac
      done < <(git -C "$destination" diff --no-color -U0 -- "$file" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ')
    }
    restore=()
    keep=()
    local_work=0
    while IFS= read -r -d "" entry; do
      case "$entry" in
        "?? .kiro/"* | "?? .code-review-graph/"*) ;;
        "?? .gitignore")
          [[ "$(cat "$destination/.gitignore")" == $'# Added by code-review-graph\n.code-review-graph/' ]] || local_work=1
          ;;
        " M .gitignore")
          if crg_gitignore_only .gitignore; then restore+=(.gitignore); else local_work=1; fi
          ;;
        " M .kiro/settings/mcp.json")
          restore+=(.kiro/settings/mcp.json)
          keep+=(.kiro/settings/mcp.json)
          ;;
        *) local_work=1 ;;
      esac
    done < <(git -C "$destination" status --porcelain -z)
    if (( local_work )); then
      echo "Skipping dirty checkout (preserved, not reset): $name"
      exit 3
    fi

    saved="$(mktemp -d)"
    trap 'rm -rf "$saved"' EXIT
    for file in "''${keep[@]}"; do
      cp "$destination/$file" "$saved/$(basename "$file")"
    done
    put_back() {
      for file in "''${keep[@]}"; do
        cp "$saved/$(basename "$file")" "$destination/$file"
      done
    }
    if (( ''${#restore[@]} )); then
      git -C "$destination" checkout -- "''${restore[@]}"
    fi

    if ! git -C "$destination" fetch --prune origin; then
      echo "Local fetch failed: $name" >&2
      put_back
      exit 1
    fi
    upstream="$(git -C "$destination" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]] || ! git -C "$destination" merge --ff-only "$upstream"; then
      echo "Fast-forward failed or no upstream exists: $name" >&2
      put_back
      exit 1
    fi
    put_back
    echo "Updated: $name"
  '';
}
