{
  lib,
  pkgs,
  ...
}:

# AWS Client VPN (SAML/SSO) tooling for Linux, packaged the Nix-native way.
#
# AWS only ships an official Linux client as an Ubuntu .deb (Mono, closed
# source), which does not install on Fedora Silverblue. This module instead
# packages the open-source approach from samm-git/aws-vpn-client:
#
#   * openvpn-aws          — nixpkgs OpenVPN pinned to 2.5.1 + the AWS
#                            `auth-federate` patch (stock 2.6.x will not apply).
#   * aws-vpn-saml-server  — a tiny Go server that catches the SAML POST on
#                            127.0.0.1:35001 (vendored, patched to honor
#                            SAML_RESPONSE_PATH).
#   * aws-vpn-connect      — wrapper that runs openvpn to get the SAML redirect,
#                            opens the browser, waits for the token, then
#                            reconnects authenticated (via sudo for the tun dev).
#
# Bringing up the tunnel needs root on the host, so `aws-vpn-connect` calls
# sudo for the final openvpn invocation — that part is inherently a privileged
# host action and cannot be owned by user-level Home Manager.
#
# To upgrade OpenVPN / the patch: bump the version + url + hash below and refresh
# with `nix-prefetch-url <url>` then `nix hash to-sri --type sha256 <hash>`.

let
  # Patched OpenVPN. The AWS patch targets 2.5.1, so pin the source there and
  # let nixpkgs' own openvpn derivation supply the openssl/lzo/build wiring.
  openvpn-aws = pkgs.openvpn.overrideAttrs (old: {
    pname = "openvpn-aws";
    version = "2.5.1-aws";
    src = pkgs.fetchurl {
      url = "https://swupdate.openvpn.org/community/releases/openvpn-2.5.1.tar.gz";
      hash = "sha256-6VgrjpRXmUvY1QASvoLCOy9GXaUUYMmyNgqB2g9OBuY=";
    };
    patches = (old.patches or [ ]) ++ [
      (pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/samm-git/aws-vpn-client/master/openvpn-v2.5.1-aws.patch";
        hash = "sha256-IYNNbcxuHrx5Qm25dUp/Pxednqov8E8n9QQdih3CPBo=";
      })
    ];
  });

  # Wrap the patched binary so it is reachable as `openvpn-aws` on PATH without
  # shadowing the system openvpn.
  openvpn-aws-bin = pkgs.runCommand "openvpn-aws-bin" { } ''
    mkdir -p $out/bin
    ln -s ${openvpn-aws}/bin/openvpn $out/bin/openvpn-aws
  '';

  # SAML callback server (vendored, stdlib-only → no vendored deps).
  saml-server = pkgs.buildGoModule {
    pname = "aws-vpn-saml-server";
    version = "0-unstable-2021-02-24";
    src = ./.;
    vendorHash = null;
    meta.mainProgram = "aws-vpn-saml-server";
  };

  runtimeDeps = [
    openvpn-aws-bin
    saml-server
    pkgs.openssl
    pkgs.bind.dnsutils # provides `dig`
    pkgs.xdg-utils # provides `xdg-open`
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gawk
  ];

  aws-vpn-connect = pkgs.writeShellApplication {
    name = "aws-vpn-connect";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./aws-vpn-connect.sh;
  };
in
{
  home.packages = [
    aws-vpn-connect
    openvpn-aws-bin
    saml-server
  ];
}
