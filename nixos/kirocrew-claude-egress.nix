# Egress proxy for sandboxed units (BACKLOG F1). One tinyproxy instance on
# loopback is the only way out for units that set IPAddressDeny = "any" plus
# IPAddressAllow = "localhost" and point HTTPS_PROXY at it. The host filter is
# default-deny: CONNECT (443 only) and plain HTTP requests reach only the hosts
# below. IMDS (169.254.169.254) is not listed, so it is refused. Every allowed
# host is a possible exfil channel; that risk is accepted in BACKLOG F1.
{ lib, pkgs, ... }:
let
  allowedHosts = [
    # Claude Code API, login and token refresh
    "api.anthropic.com"
    "claude.ai"
    "claude.com"
    "platform.claude.com"
    # package registries (read; the sandbox uid has no publish tokens)
    "registry.npmjs.org"
    "pypi.org"
    "files.pythonhosted.org"
    "crates.io"
    "index.crates.io"
    "static.crates.io"
    # git and tarball dependencies (read-only: no credentials on the uid)
    "github.com"
    "codeload.github.com"
    "objects.githubusercontent.com"
    # GitLab over HTTPS: claude-remote pushes and creates merge requests with
    # a token limited to that (see kirocrew-claude-remote.nix)
    "gitlab.com"
    # standard NixOS hosts, so nix-shell -p and substitution work
    "cache.nixos.org"
    "channels.nixos.org"
    "releases.nixos.org"
    "tarballs.nixos.org"
  ];
  # One anchored ERE per host: exact match, no subdomains.
  hostFilter = pkgs.writeText "tinyproxy-host-filter" (
    lib.concatMapStrings (h: "^${lib.replaceStrings [ "." ] [ "\\." ] h}$\n") allowedHosts
  );
in
{
  services.tinyproxy = {
    enable = true;
    settings = {
      Listen = "127.0.0.1";
      Port = 8888;
      Allow = "127.0.0.1";
      ConnectPort = 443;
      Filter = hostFilter;
      FilterType = "ere";
      FilterDefaultDeny = true;
    };
  };

  # nix-daemon and every build it forks (they share its cgroup) can reach only
  # loopback, so `nix-shell -p` from a sandboxed uid substitutes and fetches
  # through the proxy and nowhere else. Deploys are not routed through here:
  # nixos-rebuild --target-host/--build-host (kirocrew-ec2.nix:6,
  # kirocrew_ec2/launcher.py _rebuild_nixos) runs nix as root in the SSH
  # session, outside nix-daemon.service. Not verified on the box: whether
  # builtin:fetchurl in fixed-output builds honours the proxy env; if not,
  # those fetches fail closed. Uncached builds needing other hosts fail by
  # design.
  systemd.services.nix-daemon = {
    serviceConfig = {
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };
    environment = {
      http_proxy = "http://127.0.0.1:8888";
      https_proxy = "http://127.0.0.1:8888";
    };
  };
}
