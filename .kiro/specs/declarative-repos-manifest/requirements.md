# Requirements

## Requirement 1: Single manifest drives all repository operations

The system SHALL use `config/repos.toml` as the single source of truth for which repositories exist on every host.

1. WHEN the local `home-manager switch` activation runs, THEN it SHALL clone missing repositories from the manifest
2. WHEN the EC2 launcher deploys a host, THEN it SHALL clone/pull repositories listed in the same manifest (no hard-coded list)
3. WHEN a repository is added to or removed from the manifest, THEN the next activation or deployment SHALL reflect the change

## Requirement 2: Unified clone destination convention

The system SHALL use a single, consistent destination path convention across local and remote hosts.

1. WHEN the manifest specifies `path = "code/readpeak/mononode"`, THEN the repository SHALL be cloned to `$HOME/code/readpeak/mononode` on both local and EC2 hosts
2. WHEN the current local activation uses `~/ReadPeak/` and the EC2 launcher uses `~/code/readpeak/`, THEN the migration SHALL converge on one convention
3. WHEN the `code-review-graph` registration scans for repos, THEN it SHALL derive the scan directory from the manifest paths (not hard-coded `~/ReadPeak`)

## Requirement 3: Per-repo metadata supports selective sync

The manifest SHALL support optional per-repo metadata that controls sync behavior.

1. WHEN a repo entry has `shallow = true`, THEN it SHALL be cloned with `--depth=1`
2. WHEN a repo entry has `shallow = false` or omits the field, THEN it SHALL be cloned with full history
3. WHEN a repo entry has `targets = ["workstation"]`, THEN it SHALL only be cloned on hosts with `kirocrew.role = "workstation"`
4. WHEN a repo entry has `targets = ["headless", "workstation"]` or omits `targets`, THEN it SHALL be cloned on all hosts

## Requirement 4: Activation is idempotent and non-destructive

The clone activation SHALL be safe to run repeatedly.

1. WHEN the target directory already exists, THEN the activation SHALL skip that repository (no pull, no reset)
2. WHEN a clone fails (network error, auth failure), THEN the activation SHALL log the failure and continue with remaining repos
3. WHEN a repo is removed from the manifest, THEN the activation SHALL NOT delete the existing directory

## Requirement 5: Manifest is readable without Nix tooling

The manifest SHALL use a simple, human-readable format parseable without Nix-specific tooling.

1. WHEN an operator edits the manifest, THEN they SHALL use standard TOML syntax
2. WHEN the EC2 launcher (Python) reads the manifest, THEN it SHALL parse it with `tomllib` (stdlib, no extra dependency)
3. WHEN the activation script reads the manifest, THEN it SHALL parse it with Python's `tomllib` (already used today)
