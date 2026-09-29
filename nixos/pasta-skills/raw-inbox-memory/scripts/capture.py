#!/usr/bin/env python3
"""Append one user-provided statement to Pasta's raw personal inbox."""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import sys
import tomllib

KINDS = {"fact", "preference", "decision", "commitment", "relationship", "routine", "note"}
SECRET_MARKERS = (
    "password", "passphrase", "api key", "api_key", "private key", "private_key",
    "recovery code", "recovery_code", "one-time password", "otp code",
)


def resolve_vault(explicit):
    if explicit:
        return explicit.expanduser().resolve()
    if os.environ.get("PASTA_VAULT_PATH"):
        return Path(os.environ["PASTA_VAULT_PATH"]).expanduser().resolve()
    config = Path("~/.pasta/config.toml").expanduser()
    if config.exists():
        with config.open("rb") as stream:
            value = tomllib.load(stream).get("general", {}).get("vault_path")
        if isinstance(value, str) and value.strip():
            return Path(value).expanduser().resolve()
    raise ValueError("Pasta vault not configured; pass --vault, set PASTA_VAULT_PATH, or configure ~/.pasta/config.toml")


def main():
    parser = argparse.ArgumentParser(description="Append a raw user-provided memory")
    parser.add_argument("--vault", type=Path)
    parser.add_argument("--kind", choices=sorted(KINDS), required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--context")
    args = parser.parse_args()
    text = args.text.strip()
    if not text:
        raise ValueError("capture text is empty")
    if any(marker in text.casefold() for marker in SECRET_MARKERS):
        raise ValueError("capture looks like it may contain a credential; refusing")

    now = datetime.now(timezone.utc)
    digest = hashlib.sha256((now.isoformat() + "\0" + args.kind + "\0" + args.source + "\0" + text).encode()).hexdigest()[:10]
    path = resolve_vault(args.vault) / "0. Inbox" / "Raw" / f"{now:%Y%m%dT%H%M%S.%fZ}-{digest}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    quoted = lambda value: json.dumps(value, ensure_ascii=False)
    body = ["---", "raw_capture: 1", f"captured_at: {quoted(now.isoformat())}", f"kind: {quoted(args.kind)}", f"source: {quoted(args.source)}", 'status: "raw"', "---", "", "# Raw capture", "", text]
    if args.context:
        body += ["", "## Context", "", args.context.strip()]
    try:
        with path.open("x", encoding="utf-8") as stream:
            stream.write("\n".join(body) + "\n")
    except FileExistsError as error:
        raise ValueError("capture filename collision; retry") from error
    print(path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        print(f"raw-inbox-capture: {error}", file=sys.stderr)
        raise SystemExit(2)
