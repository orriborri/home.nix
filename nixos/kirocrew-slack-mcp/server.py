#!/usr/bin/env python3
"""kirocrew-slack-mcp — a small, auditable stdio MCP server for Slack.

Wraps the Slack Web API using a single user token supplied via the SLACK_TOKEN
environment variable (the gateway composes it from the shared sops `slack-token`
— the SAME secret the pasta fetch helper uses). No OAuth flow, no token file, no
refresh: the token is static (`xoxp-...`) and read once from the environment.

Design mirrors the cfm-tips MCP server: a self-contained Python module the
gateway spawns over stdio, with only `mcp` as a non-stdlib dependency. Slack
calls use urllib (stdlib) so the venv stays minimal and reviewable.

Tools (scoped to what the pasta token already grants):
  Read
    slack_auth_test           — who am I / is the token valid (auth.test)
    slack_search_messages     — search messages (search.messages)
    slack_list_channels       — list channels/groups/ims (conversations.list)
    slack_channel_history     — recent messages in a channel (conversations.history)
    slack_user_info           — look up a user (users.info)
  Write (guarded — the assistant confirms intent before calling)
    slack_post_message        — post a message to a channel (chat.postMessage)

Every tool returns the raw Slack API JSON (or a structured error), so the
calling agent sees exactly what Slack returned and can reason about `ok`/`error`.
"""

from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request
from typing import Any

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

SLACK_API = "https://slack.com/api"
TOKEN = os.environ.get("SLACK_TOKEN", "").strip()

server = Server("slack")


def _call(method: str, params: dict[str, Any], *, post: bool = False) -> dict[str, Any]:
    """Call one Slack Web API method and return its parsed JSON.

    GET for read methods, POST (form-encoded) for write methods. Auth is the
    bearer token from the environment. Any transport/parse failure is returned
    as a structured error dict rather than raised, so the agent always gets a
    JSON-shaped answer it can reason about.
    """
    if not TOKEN:
        return {"ok": False, "error": "no_slack_token_in_environment"}

    # Drop unset optional args so we never send empty strings Slack rejects.
    clean = {k: v for k, v in params.items() if v is not None and v != ""}
    headers = {"Authorization": f"Bearer {TOKEN}"}

    try:
        if post:
            data = urllib.parse.urlencode(clean).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            req = urllib.request.Request(f"{SLACK_API}/{method}", data=data, headers=headers)
        else:
            qs = urllib.parse.urlencode(clean)
            url = f"{SLACK_API}/{method}" + (f"?{qs}" if qs else "")
            req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:  # noqa: BLE001 — report, don't crash
        return {"ok": False, "error": f"http_{e.code}", "detail": e.reason}
    except Exception as e:  # noqa: BLE001 — report, don't crash the server
        return {"ok": False, "error": "request_failed", "detail": str(e)}


def _result(payload: dict[str, Any]) -> list[TextContent]:
    return [TextContent(type="text", text=json.dumps(payload, indent=2))]


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="slack_auth_test",
            description="Verify the Slack token and return the authed user/team (auth.test). Use to confirm connectivity and identity.",
            inputSchema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        Tool(
            name="slack_search_messages",
            description="Search Slack messages (search.messages). Supports Slack search operators, e.g. 'to:me', 'in:#eng', 'from:@alice'.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Slack search query"},
                    "count": {"type": "integer", "description": "Max results (default 20)", "default": 20},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        ),
        Tool(
            name="slack_list_channels",
            description="List conversations (conversations.list). types is a comma list: public_channel,private_channel,mpim,im.",
            inputSchema={
                "type": "object",
                "properties": {
                    "types": {"type": "string", "description": "Comma-separated conversation types", "default": "public_channel,private_channel"},
                    "limit": {"type": "integer", "description": "Max results (default 100)", "default": 100},
                },
                "additionalProperties": False,
            },
        ),
        Tool(
            name="slack_channel_history",
            description="Fetch recent messages from a channel/conversation (conversations.history). Pass the channel ID (e.g. C0123 or D0123).",
            inputSchema={
                "type": "object",
                "properties": {
                    "channel": {"type": "string", "description": "Channel/conversation ID"},
                    "limit": {"type": "integer", "description": "Max messages (default 30)", "default": 30},
                },
                "required": ["channel"],
                "additionalProperties": False,
            },
        ),
        Tool(
            name="slack_user_info",
            description="Look up a Slack user by ID (users.info).",
            inputSchema={
                "type": "object",
                "properties": {"user": {"type": "string", "description": "User ID (e.g. U0123)"}},
                "required": ["user"],
                "additionalProperties": False,
            },
        ),
        Tool(
            name="slack_post_message",
            description="Post a message to a channel/conversation as the token's user (chat.postMessage). WRITE ACTION — the caller must confirm intent before using this. Pass the channel ID and message text.",
            inputSchema={
                "type": "object",
                "properties": {
                    "channel": {"type": "string", "description": "Channel/conversation ID to post to"},
                    "text": {"type": "string", "description": "Message text (mrkdwn)"},
                    "thread_ts": {"type": "string", "description": "Optional parent message ts to reply in-thread"},
                },
                "required": ["channel", "text"],
                "additionalProperties": False,
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    a = arguments or {}
    if name == "slack_auth_test":
        return _result(_call("auth.test", {}, post=True))
    if name == "slack_search_messages":
        return _result(_call("search.messages", {"query": a.get("query"), "count": a.get("count", 20)}))
    if name == "slack_list_channels":
        return _result(_call("conversations.list", {"types": a.get("types", "public_channel,private_channel"), "limit": a.get("limit", 100)}))
    if name == "slack_channel_history":
        return _result(_call("conversations.history", {"channel": a.get("channel"), "limit": a.get("limit", 30)}))
    if name == "slack_user_info":
        return _result(_call("users.info", {"user": a.get("user")}))
    if name == "slack_post_message":
        return _result(_call("chat.postMessage", {"channel": a.get("channel"), "text": a.get("text"), "thread_ts": a.get("thread_ts")}, post=True))
    return _result({"ok": False, "error": "unknown_tool", "detail": name})


async def _amain() -> None:
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


def main() -> None:
    import asyncio

    asyncio.run(_amain())


if __name__ == "__main__":
    main()
