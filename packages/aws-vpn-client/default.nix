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
#   * openvpn-aws          — nixpkgs OpenVPN (2.6 series) + the AWS
#                            `auth-federate` patch.
#   * aws-vpn-saml-server  — a tiny Go server that catches the SAML POST on
#                            127.0.0.1:35001 (vendored, patched to honor
#                            SAML_RESPONSE_PATH).
#   * aws-vpn-connect      — wrapper that runs openvpn to get the SAML redirect,
#                            opens the browser, waits for the token, then
#                            reconnects authenticated (via sudo for the tun dev).
#   * aws-vpn-connect-{staging,prod}
#                          — thin wrappers defaulting to the matching per-env
#                            profile under ~/.config/aws-vpn-client/.
#   * aws-vpn-fetch-config — download + prepare a profile from AWS (SSM endpoint
#                            lookup, export, strip conflicting directives).
#
# Bringing up the tunnel needs root on the host, so `aws-vpn-connect` calls
# sudo for the final openvpn invocation — that part is inherently a privileged
# host action and cannot be owned by user-level Home Manager.
#
# OpenVPN itself comes from nixpkgs, so a nixpkgs bump moves it; if a bump
# ever breaks the patch, replace ./openvpn-v2.6.12-aws.patch with the matching
# one from https://github.com/samm-git/aws-vpn-client (vendored, so a moved or
# deleted upstream branch cannot break or change the build).
#
# Upstream was archived on 2026-02-05 at commit
# 41610c3c5a3e10fe5a76bdd21d5b6779b789f812 and migrated to
# github.com/aws-vpn-client/aws-vpn-client (same files). Besides the 2.5.1
# patch it ships one for the 2.6 series, added 2025-05-01 in d61ec72 (#28)
# (S11.2, checked 2026-10-07):
#   https://github.com/samm-git/aws-vpn-client/blob/41610c3c5a3e10fe5a76bdd21d5b6779b789f812/openvpn-v2.6.12-aws.patch
#   sha256-Vh8Ih6cENFLP9V8xQFOfGMemPpFDQwR8mPgqEh81ZFc=
# It touches buffer.h, common.h, error.h, manage.c, manage.h, misc.h,
# options.h and ssl.c, and `patch -p1 --dry-run` applies it to nixpkgs'
# openvpn 2.6.23 with offsets only. Upstream also carries
# openssl-v3.0.14-aws-000-revert-self-signed-cert-logic.patch; this package
# builds against nixpkgs' unpatched openssl and does not apply it; PR #28
# notes it "doesn't seem to be necessary for the vpn to work".

let
  # Patched OpenVPN: nixpkgs' own openvpn derivation (source, openssl/lzo and
  # build wiring) plus the AWS patch for the 2.6 series.
  openvpn-aws = pkgs.openvpn.overrideAttrs (old: {
    pname = "openvpn-aws";
    patches = (old.patches or [ ]) ++ [ ./openvpn-v2.6.12-aws.patch ];
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

  # OpenVPN supplies dev and script_type to hooks running as root.
  prod-dns-hook = pkgs.writeShellApplication {
    name = "aws-vpn-prod-dns";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      VPN_DNS_INTERFACE="''${dev:?}"
      case "''${script_type:?}" in
        up)
          trap 'resolvectl revert "$VPN_DNS_INTERFACE"' ERR
          resolvectl dns "$VPN_DNS_INTERFACE" 172.30.0.2
          resolvectl domain "$VPN_DNS_INTERFACE" '~opensearch.readpeak.net'
          resolvectl default-route "$VPN_DNS_INTERFACE" no
          ;;
        down)
          resolvectl revert "$VPN_DNS_INTERFACE"
          ;;
      esac
    '';
  };

  # Per-environment convenience wrappers. ReadPeak runs two separate Client VPN
  # endpoints (staging and prod, each its own SAML application), so each has its
  # own downloaded profile. These default to a fixed per-env path under
  # ~/.config/aws-vpn-client/ but still accept an explicit config argument.
  mkEnvConnect =
    env:
    pkgs.writeShellApplication {
      name = "aws-vpn-connect-${env}";
      runtimeInputs = [ aws-vpn-connect ];
      text =
        lib.optionalString (env == "prod") ''
          export VPN_DNS_HOOK=${prod-dns-hook}/bin/aws-vpn-prod-dns
        ''
        + ''
          exec aws-vpn-connect "''${1:-$HOME/.config/aws-vpn-client/${env}.ovpn}"
        '';
    };

  aws-vpn-connect-staging = mkEnvConnect "staging";
  aws-vpn-connect-prod = mkEnvConnect "prod";

  # Fetch + prepare a profile: SSM endpoint lookup, export, strip conflicting
  # directives. Needs the AWS CLI and a valid session (aws login).
  aws-vpn-fetch-config = pkgs.writeShellApplication {
    name = "aws-vpn-fetch-config";
    runtimeInputs = [
      pkgs.awscli2
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = builtins.readFile ./aws-vpn-fetch-config.sh;
  };
in
{
  home.packages = [
    aws-vpn-connect
    aws-vpn-connect-staging
    aws-vpn-connect-prod
    aws-vpn-fetch-config
    openvpn-aws-bin
    saml-server
  ];
}
