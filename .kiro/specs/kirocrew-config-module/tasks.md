# Tasks

## 1. Create `kirocrew-config.nix` module

- [x] 1.1 Create `kirocrew-config.nix` at repo root with `kirocrew.enable` and `kirocrew.role` options
- [x] 1.2 Add `xdg.configFile."kirocrew/repos.toml".source = ./config/repos.toml` under `config = lib.mkIf cfg.enable`
- [x] 1.3 Add `programs.ssh.knownHosts` entries for `gitlab.com` and `github.com` (ed25519 keys)
- [x] 1.4 Import `./kirocrew-config.nix` in `home.nix` imports list

## 2. Update `development.nix` to use XDG manifest path

- [x] 2.1 Change `MANIFEST` path from `$HOME/.config/home-manager/config/repos.toml` to `$HOME/.config/kirocrew/repos.toml`
- [x] 2.2 Add fallback: try old path if new path doesn't exist (transition period)
- [x] 2.3 Update `crgRegisterRepos` to derive repo base directory from `repos.toml` paths instead of hard-coded `$HOME/ReadPeak`

## 3. Update EC2 launcher to consume `repos.toml`

- [x] 3.1 Add a `_read_repos_manifest(remote)` method that reads `~/.config/kirocrew/repos.toml` from the remote via SSH
- [x] 3.2 Parse the TOML with `tomllib` and return list of `{remote, path}` entries
- [x] 3.3 Replace the hard-coded repo list in `_sync_repositories` with the parsed manifest
- [x] 3.4 Unify clone destination convention: use `~/` + `repo.path` from the manifest (matching local behavior)

## 4. Set `kirocrew.role` per profile in `flake.nix`

- [x] 4.1 Add `kirocrew.enable = true; kirocrew.role = "workstation";` to the `orre` homeConfiguration
- [x] 4.2 Add `kirocrew.enable = true; kirocrew.role = "headless";` to the `kirocrew-ec2` HM user module
- [x] 4.3 Add `kirocrew.enable = true; kirocrew.role = "headless";` to the local `kirocrew` VM HM user module
- [x] 4.4 Add `kirocrew.enable = true; kirocrew.role = "headless";` to the AMI HM user module

## 5. Remove redundant launcher known_hosts injection

- [x] 5.1 Remove the `known_hosts` concatenation step from `_sync_repositories` (now declarative)
- [ ] 5.2 Verify the remote's `~/.ssh/known_hosts` contains the expected keys after `nixos-rebuild switch`

## 6. Validate

- [ ] 6.1 Run `nix flake check` -- all outputs evaluate without error
- [ ] 6.2 Run `home-manager build --flake .` -- verify `repos.toml` symlink appears in result
- [ ] 6.3 Verify `~/.config/kirocrew/repos.toml` is a symlink to the Nix store after `home-manager switch`
- [ ] 6.4 Verify `~/.ssh/known_hosts` contains gitlab.com and github.com entries
- [ ] 6.5 Test EC2 deploy: `launch-ec2 start` -- repos cloned from manifest, no known_hosts error
