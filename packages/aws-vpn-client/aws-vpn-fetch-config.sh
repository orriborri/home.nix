#!/usr/bin/env bash
#
# aws-vpn-fetch-config — download and prepare an AWS Client VPN profile for the
# OSS SAML flow driven by aws-vpn-connect.
#
# Looks up the endpoint ID from SSM (/client-vpn/endpoint/endpoint-id, exported
# by the ReadPeak cdk client-vpn stack), exports the client configuration, and
# strips the directives that conflict with this flow. The result is written to
# ~/.config/aws-vpn-client/<env>.ovpn, which aws-vpn-connect-<env> reads.
#
# Usage:
#   aws-vpn-fetch-config <env> <aws-profile> [region]
#
# Examples:
#   aws-vpn-fetch-config staging StagingAdmin
#   aws-vpn-fetch-config prod    ProdAdmin
#
# Requires a valid AWS session for the given profile (run `aws login` first).

set -euo pipefail

ENV="${1:?usage: aws-vpn-fetch-config <env> <aws-profile> [region]}"
PROFILE="${2:?usage: aws-vpn-fetch-config <env> <aws-profile> [region]}"
REGION="${3:-eu-central-1}"

OUTDIR="$HOME/.config/aws-vpn-client"
OUT="$OUTDIR/${ENV}.ovpn"
mkdir -p "$OUTDIR"

echo "Looking up Client VPN endpoint ID from SSM (profile: $PROFILE, region: $REGION)..."
ENDPOINT_ID="$(aws ssm get-parameter \
  --name /client-vpn/endpoint/endpoint-id \
  --profile "$PROFILE" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)"

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "None" ]]; then
  echo "SSM lookup failed; falling back to describe-client-vpn-endpoints..." >&2
  ENDPOINT_ID="$(aws ec2 describe-client-vpn-endpoints \
    --profile "$PROFILE" --region "$REGION" \
    --query 'ClientVpnEndpoints[0].ClientVpnEndpointId' --output text 2>/dev/null || true)"
fi

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "None" ]]; then
  echo "error: could not determine the Client VPN endpoint ID." >&2
  echo "Check that the profile is authenticated (aws login) and has access." >&2
  exit 1
fi
echo "Endpoint: $ENDPOINT_ID"

echo "Exporting client configuration..."
RAW="$(aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id "$ENDPOINT_ID" \
  --profile "$PROFILE" --region "$REGION" \
  --output text)"

# Strip the directives that conflict with the OSS SAML flow. aws-vpn-connect
# supplies its own --auth-user-pass and --remote, and must not be prompted or
# told to retry interactively. The <ca> block and verify-x509-name are kept.
printf '%s\n' "$RAW" \
  | grep -vE '^auth-federate' \
  | grep -vE '^auth-retry interact' \
  | grep -vE '^auth-user-pass' \
  > "$OUT"

chmod 600 "$OUT"
echo "Wrote $OUT"
echo
echo "Endpoint directives (secrets hidden):"
grep -vE '^\s*$' "$OUT" \
  | grep -viE 'BEGIN|END|^[A-Za-z0-9+/=]{40,}$' \
  | grep -vE '^</?(ca|cert|key)>' \
  | sed 's/^/  /'
echo
echo "Connect with: aws-vpn-connect-${ENV}"
