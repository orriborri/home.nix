#!/usr/bin/env bash
#
# aws-vpn-connect — connect to an AWS Client VPN endpoint that uses SAML/SSO
# federated authentication, using the patched OSS OpenVPN.
#
# Adapted from https://github.com/samm-git/aws-vpn-client (aws-connect.sh).
# Runtime dependencies (openvpn-aws, aws-vpn-saml-server, openssl, dig,
# xdg-open) are put on PATH by the Nix wrapper in default.nix.
#
# Usage:
#   aws-vpn-connect [path/to/config.ovpn]
#
# The config defaults to ~/.config/aws-vpn-client/vpn.conf. The endpoint
# hostname is read from the config's `remote` line; override with VPN_HOST.
#
# Requires sudo for the second openvpn invocation (creates the tun device).

set -euo pipefail

OVPN_CONF="${1:-$HOME/.config/aws-vpn-client/vpn.conf}"
PROTO="${VPN_PROTO:-udp}"
PORT="${VPN_PORT:-443}"

if [[ ! -f "$OVPN_CONF" ]]; then
  echo "error: config not found: $OVPN_CONF" >&2
  echo "Download it from the AWS Client VPN endpoint (\"Download client configuration\")," >&2
  echo "then pass its path or place it at ~/.config/aws-vpn-client/vpn.conf" >&2
  exit 1
fi

# Determine the endpoint host: explicit VPN_HOST wins, else the config's remote.
if [[ -z "${VPN_HOST:-}" ]]; then
  VPN_HOST="$(awk '/^remote /{print $2; exit}' "$OVPN_CONF")"
fi
if [[ -z "${VPN_HOST:-}" ]]; then
  echo "error: could not determine VPN host. Set VPN_HOST or add a 'remote' line to the config." >&2
  exit 1
fi

# Private working dir for the SAML response (never in cwd).
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-vpn.XXXXXX")"
export SAML_RESPONSE_PATH="$WORKDIR/saml-response.txt"

SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

wait_file() {
  local file="$1"
  local wait_seconds="${2:-30}"
  until [[ "$wait_seconds" -eq 0 || -f "$file" ]]; do
    sleep 1
    wait_seconds=$((wait_seconds - 1))
  done
  [[ -f "$file" ]]
}

# Start the SAML callback server (writes to $SAML_RESPONSE_PATH).
aws-vpn-saml-server &
SERVER_PID=$!

# Random hostname prefix, resolved to a stable IP (AWS uses per-connection prefixes).
RAND="$(openssl rand -hex 12)"
SRV="$(dig a +short "${RAND}.${VPN_HOST}" | head -n1)"
if [[ -z "$SRV" ]]; then
  echo "error: failed to resolve ${RAND}.${VPN_HOST}" >&2
  exit 1
fi

echo "Getting SAML redirect URL from the AUTH_FAILED response (host: ${SRV}:${PORT})"
OVPN_OUT="$(openvpn-aws --config "$OVPN_CONF" --verb 3 \
  --proto "$PROTO" --remote "$SRV" "$PORT" \
  --auth-user-pass <(printf "%s\n%s\n" "N/A" "ACS::35001") \
  2>&1 | grep AUTH_FAILED,CRV1)" || {
    echo "error: did not receive a SAML challenge from the endpoint." >&2
    echo "Check that the endpoint uses SAML auth and the config is correct." >&2
    exit 1
  }

URL="$(echo "$OVPN_OUT" | grep -Eo 'https://.+')"
echo "Opening browser for SAML login..."
xdg-open "$URL" >/dev/null 2>&1 || echo "Open this URL manually: $URL"

if ! wait_file "$SAML_RESPONSE_PATH" 60; then
  echo "error: SAML authentication timed out." >&2
  exit 1
fi

VPN_SID="$(echo "$OVPN_OUT" | awk -F : '{print $7}')"

echo "Connecting (sudo required to create the tun device)..."
sudo openvpn-aws --config "$OVPN_CONF" \
  --verb 3 --auth-nocache --inactive 3600 \
  --proto "$PROTO" --remote "$SRV" "$PORT" \
  --script-security 2 \
  --auth-user-pass <(printf "%s\n%s\n" "N/A" "CRV1::${VPN_SID}::$(cat "$SAML_RESPONSE_PATH")")
