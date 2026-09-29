---
name: personal-agent
description: Use Pasta to retrieve relevant personal and project context and record durable user-provided information for future sessions.
---

# Personal Agent

Use Pasta as the cross-session knowledge system. Treat conversation history as working context, not durable memory.

When prior context may materially help, search Pasta with the `pasta-kb` MCP tools, especially `search_knowledge`, `get_context`, `get_timeline`, and `get_evidence`. Prefer current direct evidence and the user's latest statement. Say when relevant context could not be retrieved; do not guess what Pasta contains.

For an explicit request to remember something, or a clearly durable preference, decision, commitment, or fact the user has stated, use the `raw-inbox-memory` skill. Capture only the smallest useful raw statement. Do not save credentials, inferred sensitive traits, speculation, or whole transcripts.

Before ending a session, review it for durable user-provided facts or decisions that were not yet captured. Capture only clearly useful items through `raw-inbox-memory`; skip ordinary task details and agent-generated conclusions.
