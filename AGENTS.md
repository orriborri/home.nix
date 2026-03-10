# Repository Guidelines

## Project Structure & Module Organization
`flake.nix` exposes every output, while `home.nix` stitches together the default configuration. Daily work happens in `modules/`, organized by domain (`development/`, `shell/`, `desktop/`, `wm/sway/`) and merged by `modules/default.nix`. Shared helpers stay in `lib/`, reusable packages live in `packages/`, overlays in `overlays/`, and host-specific glue in `nixos/`. Reach for `templates/minimal` when seeding a new profile.

## Build, Test, & Development Commands
- `nix develop` — launch the repo’s toolchain (formatter, hm, git helpers).
- `nix flake show` — list module, package, and template outputs.
- `nix flake check` — evaluate modules, overlays, and packages in CI-equivalent mode.
- `home-manager build --flake .` — dry-run profile activation without touching `$HOME`.
- `home-manager switch --flake .#orre` (or `.#orre-minimal`) — apply a specific configuration.
- `nix run .#update` (or `./update.sh`) — bump inputs and rebuild using the scripted order.

## Coding Style & Naming Conventions
`.editorconfig` enforces LF endings, trimmed whitespace, and space-based indentation. Use two spaces for Nix, YAML, JSON, shell, and JavaScript files; Python alone keeps four. Run `nix fmt` before committing so formatter drift never lands in review. Name modules after their function (`modules/development/git.nix`, `modules/wm/sway/inputs.nix`), keep derivations pure, and add comments only when necessary.

## Testing Guidelines
Treat `nix flake check` as the minimum bar for every change. Follow it with `home-manager build --flake .` to catch evaluation regressions, then `home-manager switch --flake .#orre-minimal` whenever the tweak touches outputs shared with the minimal profile or templates. Use `nix develop .#test` for linting/shellcheck and list the commands you ran in the PR.

## Commit & Pull Request Guidelines
History favors Conventional Commits (`feat:`, `fix:`, `chore:`, etc.), so write imperative messages that cover one logical change and cite issues in the footer when needed. Pull requests should include a short motivation, screenshots for UI-facing Sway/Waybar edits, the exact commands you ran (see Testing), and the target platform (`x86_64-linux`, `aarch64-darwin`, etc.).

## Security & Configuration Tips
Security knobs belong in `modules/security.nix`; reference GPG key IDs or `pass` stores rather than committing secrets. Keep overlays tight (e.g., `overlays/nodejs.nix`) and bump versions via `nix flake update` followed by `nix run .#update` to avoid drift between lockfiles and scripts. New templates or scripts must default to safe flags and explicitly call the intended flake output (`.#orre`, `.#orre@darwin`).
