"""Classify a cached mcp-remote OAuth token by actually using it.

This module is deliberately standalone — it imports nothing from the rest of the
package — because it runs in two places:

* imported by the launcher, to judge the workstation's own cached tokens;
* shipped to the gateway (base64'd onto a `python3 -` command line) to judge the
  copy that lives there.

One implementation serves both so the two sides cannot drift into disagreeing
about what "valid" means. The gateway keeps its own tokens fresh — long-lived
`mcp-remote` processes there refresh them on use — so the launcher must ask the
gateway before it considers overwriting anything, and that question has to be
asked with the same rules the local check uses.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# A token copied to the gateway is a STATIC snapshot, so "valid right now" is not
# enough — it has to stay valid long enough there to be worth installing.
#
# Capped per-token by half the token's own lifetime (see `classify`): a provider
# that issues 1-hour tokens can never satisfy a 12-hour floor, and an uncapped
# floor would demand a fresh browser login on every run while still calling the
# brand-new token stale.
DEFAULT_MIN_REMAINING_SECS = 12 * 3600

# Status values, strongest first. `expired` is separated from `stale` because
# they need different remedies: an expired token can often be renewed silently
# from its refresh token, while a stale one cannot — mcp-remote reuses a token
# that is still valid instead of refreshing it, so a stale one must be cleared.
STATUS_OK = "ok"
STATUS_STALE = "stale"
STATUS_EXPIRED = "expired"
STATUS_REJECTED = "rejected"
STATUS_ABSENT = "absent"
STATUS_UNKNOWN = "unknown"

_INITIALIZE = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "launch-ec2-auth-probe", "version": "1.0"},
    },
}


def classify(
    server_url: str,
    token_path: str | Path,
    min_remaining_secs: float = DEFAULT_MIN_REMAINING_SECS,
) -> tuple[str, str, float | None]:
    """Return (status, detail, remaining_secs) for one cached token.

    `remaining_secs` is None when the file records no expiry; callers use it to
    compare two copies of the same credential and refuse to replace a fresher
    one with a staler one.

    Two checks, cheapest first: `expires_at` (epoch ms, written by mcp-remote)
    rules out a dead token with no network call, then an authenticated MCP
    `initialize` decides it — only the server can say whether a token that
    merely LOOKS current has been revoked.
    """
    path = Path(token_path)
    if not path.is_file():
        return STATUS_ABSENT, "no cached token", None
    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return STATUS_ABSENT, f"unreadable token file ({type(error).__name__})", None

    access_token = payload.get("access_token")
    if not isinstance(access_token, str) or not access_token:
        return STATUS_ABSENT, "token file has no access_token", None

    remaining: float | None = None
    floor = float(min_remaining_secs)
    expires_at = payload.get("expires_at")
    if isinstance(expires_at, (int, float)):
        remaining = expires_at / 1000.0 - time.time()
        if remaining <= 0:
            return STATUS_EXPIRED, f"expired {abs(remaining) / 3600:.1f}h ago", remaining
        lifetime = payload.get("expires_in")
        if isinstance(lifetime, (int, float)) and lifetime > 0:
            floor = min(floor, float(lifetime) / 2.0)

    request = urllib.request.Request(
        server_url,
        data=json.dumps(_INITIALIZE).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 200:
                return (
                    STATUS_REJECTED,
                    f"probe returned HTTP {response.status}",
                    remaining,
                )
    except urllib.error.HTTPError as error:
        return (
            STATUS_REJECTED,
            f"rejected with HTTP {error.code} {error.reason}",
            remaining,
        )
    except Exception as error:  # network/DNS/TLS — cannot conclude the token is bad
        return STATUS_UNKNOWN, f"probe failed: {type(error).__name__}: {error}", remaining

    if remaining is None:
        return STATUS_OK, "probe HTTP 200, no expiry recorded", None
    if remaining < floor:
        return (
            STATUS_STALE,
            f"only {remaining / 3600:.1f}h left (floor {floor / 3600:.1f}h)",
            remaining,
        )
    return STATUS_OK, f"probe HTTP 200, {remaining / 3600:.1f}h left", remaining


def main(argv: list[str]) -> int:
    """Script entry point: `python3 - <server_url> <token_path> [floor_secs]`.

    Emits one tab-separated line — status, detail, remaining — so the caller can
    parse it without shipping a serialisation format alongside the script. No
    token material is ever printed.
    """
    if len(argv) < 3:
        print("usage: token_probe.py <server_url> <token_path> [floor_secs]", file=sys.stderr)
        return 2
    floor = float(argv[3]) if len(argv) > 3 else DEFAULT_MIN_REMAINING_SECS
    status, detail, remaining = classify(argv[1], argv[2], floor)
    print(f"{status}\t{detail}\t{'' if remaining is None else f'{remaining:.0f}'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
