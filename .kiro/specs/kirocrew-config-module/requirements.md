# Requirements

## Requirement 1: Single KiroCrew configuration module

The system SHALL provide a single `kirocrew-config.nix` Home Manager module that declaratively places all static, non-secret KiroCrew configuration files.

1. WHEN the module is imported into any Home Manager profile, THEN it SHALL place stable configuration files into the user's XDG config and data directories via `xdg.configFile` / `home.file`
2. WHEN the module is imported alongside `kirocrew-service.nix`, THEN it SHALL not conflict with or duplicate any service-level configuration
3. WHEN a configuration value contains secrets or authentication tokens, THEN it SHALL NOT be managed by this module (secrets remain under sops-nix or runtime sync)

## Requirement 2: Declarative repo manifest placement

The system SHALL place `config/repos.toml` into a well-known XDG path so both local activation scripts and EC2 launcher can consume it.

1. WHEN the module is active, THEN it SHALL install `repos.toml` at `~/.config/kirocrew/repos.toml` via `xdg.configFile`
2. WHEN `development.nix` runs its `cloneRepos` activation, THEN it SHALL read from the XDG path (`~/.config/kirocrew/repos.toml`) instead of the literal repo checkout path
3. WHEN the EC2 launcher syncs repositories, THEN it SHALL read the same manifest from the same XDG path on the remote host

## Requirement 3: Explicit target-role configuration

The module SHALL accept a `role` option to distinguish workstation from headless/EC2 deployments without probing the evaluator filesystem.

1. WHEN role is `"workstation"`, THEN the module SHALL enable interactive-only configuration (e.g. GUI clipboard helpers)
2. WHEN role is `"headless"`, THEN the module SHALL omit desktop-specific configuration
3. WHEN role is not explicitly set, THEN it SHALL default to `"workstation"`

## Requirement 4: Known-hosts management

The system SHALL declaratively manage SSH known_hosts entries required for Git operations.

1. WHEN the module is active, THEN it SHALL ensure GitLab and GitHub host keys are present in `~/.ssh/known_hosts` via Home Manager
2. WHEN the EC2 launcher previously injected known_hosts manually, THEN this module SHALL make that step redundant

## Requirement 5: No secrets in the Nix store

The module SHALL NOT place any file containing authentication tokens, private keys, or credentials into `home.file` or `xdg.configFile`.

1. WHEN `~/.kiro/crew/config.json` is needed on a remote host, THEN it SHALL continue to be synced by the launcher's `_sync_state` method at runtime
2. WHEN the Git SSH key is needed, THEN it SHALL continue to be decrypted by sops-nix at runtime
3. WHEN the age private key is needed, THEN it SHALL continue to be bootstrapped by the launcher from 1Password
