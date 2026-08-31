# Tasks

## 1. Extend `config/repos.toml` format

- [x] 1.1 Add `[settings]` table with `base_dir = "code/readpeak"`
- [x] 1.2 Update all `[[repos]]` entries: change `path` from `ReadPeak/<name>` to `code/readpeak/<name>`
- [x] 1.3 Add `shallow = true` (default) field to entries that should remain shallow
- [x] 1.4 Add `shallow = false` to entries that need full history (mononode, cdk, nativeflow, eks-workloads)
- [x] 1.5 Add `targets = ["workstation"]` to repos not needed on headless (wiki, renovate-bot, gitlab-components, spritsstudio)
- [x] 1.6 Add the `pasta` repo entry (`git@github.com:orriborri/pasta.git`, `path = "code/pasta"`)

## 2. Update `development.nix` activation to use new format

- [x] 2.1 Update `cloneRepos` to read from `$HOME/.config/kirocrew/repos.toml` with fallback to old path
- [x] 2.2 Add `KIROCREW_ROLE` filtering: skip repos whose `targets` don't include the current role
- [x] 2.3 Respect `shallow` field: use `--depth=1` when `true`, omit when `false`
- [x] 2.4 Update `crgRegisterRepos` to iterate manifest paths instead of scanning `$HOME/ReadPeak`
- [x] 2.5 Remove hard-coded `$HOME/ReadPeak` reference from `crgRegisterRepos`

## 3. Update EC2 launcher `_sync_repositories`

- [x] 3.1 Add `_read_repos_manifest(self, remote: RemoteHost) -> list[dict]` method
- [x] 3.2 Replace the hard-coded `for repo in mononode nativeflow cdk renovate-bot eks-workloads` with manifest iteration
- [x] 3.3 Replace hard-coded pasta clone with manifest entry
- [x] 3.4 Use `repo["path"]` for destination (relative to `$HOME`)
- [x] 3.5 Respect `shallow` field in clone command (`--depth=1` vs full)
- [x] 3.6 Filter by `targets` using `"headless"` as the launcher's role
- [x] 3.7 Remove the `known_hosts` inline injection (moved to declarative `programs.ssh.knownHosts` in spec #1)

## 4. Set `KIROCREW_ROLE` in `kirocrew-config.nix`

- [x] 4.1 Add `home.sessionVariables.KIROCREW_ROLE = cfg.role;` to the module config
- [x] 4.2 Verify the variable is available during activation (it's set in the activation environment)

## 5. Migration support

- [x] 5.1 Document in `README.md` or `MIGRATION.md` that `~/ReadPeak/` is deprecated in favor of `~/code/readpeak/`
- [x] 5.2 Add a one-time activation step that creates symlinks `~/ReadPeak/<name>` -> `~/code/readpeak/<name>` if old paths exist
- [x] 5.3 Set a removal date for the symlink migration (e.g., after 2 deploy cycles)

## 6. Validate

- [ ] 6.1 Run `nix flake check` -- no evaluation errors
- [ ] 6.2 Run `home-manager build --flake .` -- verify `repos.toml` content matches updated format
- [ ] 6.3 Test local activation: new repos cloned to `~/code/readpeak/`, workstation-only repos skipped on headless
- [ ] 6.4 Test EC2 deploy: `launch-ec2 start` -- repos cloned from manifest, no hard-coded list used
- [ ] 6.5 Verify `code-review-graph` registers repos from manifest paths
