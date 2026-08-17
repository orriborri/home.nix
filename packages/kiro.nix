{ pkgs, lib, config, ... }:

let
  isNixOS = builtins.pathExists /etc/NIXOS;

  # On NixOS (EC2/VM) the bwrap FHS sandbox fails because mount(/, MS_SLAVE) is
  # blocked by the virtualisation layer. Use the unwrapped binary there; on
  # non-NixOS (Silverblue, macOS) the wrapped version works fine.
  kiro-cli-pkg =
    if isNixOS then pkgs.kiro-cli.passthru.unwrapped
    else pkgs.kiro-cli;

  # The IDE is only available on x86_64-linux and aarch64-darwin.
  hasKiroIDE = builtins.elem pkgs.stdenv.hostPlatform.system [
    "x86_64-linux"
    "aarch64-darwin"
  ];
in
{
  home.packages = [
    kiro-cli-pkg
    pkgs.xdg-utils  # Required for browser-based authentication
  ] ++ lib.optionals (hasKiroIDE && !isNixOS) [
    pkgs.kiro       # IDE — skip on headless NixOS hosts and unsupported arches
  ];

  # Shell alias to default to current directory, run in background.
  # `command` prevents the alias from recursing into itself.
  programs.zsh.shellAliases = lib.mkIf (hasKiroIDE && !isNixOS) {
    kiro = "command kiro . > /dev/null 2>&1 &";
  };
}
