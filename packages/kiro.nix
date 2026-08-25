{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Use kirocrew.role to determine headless vs workstation.
  # Avoids builtins.pathExists which probes the evaluator's filesystem
  # and gives wrong results during cross-deploy (e.g. building EC2 config
  # on a Fedora laptop).
  isHeadless = (config.kirocrew or { }).role or "workstation" == "headless";

  # On headless (EC2/VM) the bwrap FHS sandbox fails because mount(/, MS_SLAVE)
  # is blocked by the virtualisation layer. Use the unwrapped binary there; on
  # workstations the wrapped version works fine.
  kiro-cli-pkg = if isHeadless then pkgs.kiro-cli.passthru.unwrapped else pkgs.kiro-cli;

  # The IDE is only available on x86_64-linux and aarch64-darwin.
  hasKiroIDE = builtins.elem pkgs.stdenv.hostPlatform.system [
    "x86_64-linux"
    "aarch64-darwin"
  ];
in
{
  home.packages = [
    kiro-cli-pkg
    pkgs.xdg-utils # Required for browser-based authentication
  ]
  ++ lib.optionals (hasKiroIDE && !isHeadless) [
    pkgs.kiro # IDE — skip on headless hosts and unsupported arches
  ];

  # Shell alias to default to current directory, run in background.
  # `command` prevents the alias from recursing into itself.
  programs.zsh.shellAliases = lib.mkIf (hasKiroIDE && !isHeadless) {
    kiro = "command kiro . > /dev/null 2>&1 &";
  };
}
