---
name: pasta-vault
description: Search and maintain the local Obsidian vault through Pasta, the Obsidian CLI, or Pasta's evidence-cited vault.py workflow.
---

# Pasta and Obsidian Vault

The configured vault is normally available from `~/.pasta/config.toml` (`[general].vault_path`). Prefer Pasta `search_knowledge` and evidence/context tools for cross-session retrieval. Use Obsidian CLI for direct note operations when Obsidian is running. For filesystem edits, preserve existing vault conventions and links.

`~/code/pasta/llm-wiki/vault.py` is a narrow evidence-cited wiki compiler, not a general vault editor. Use it only for its intended workflow: `init`, `cursor`, `plan`, `validate`, `apply`, `advance`, and `audit`. Do not route ordinary note creation, search, or edits through it.

For wiki synthesis, treat Pasta evidence as authoritative and cite factual claims with `pasta:evidence:<record_id>`. Follow `~/code/pasta/llm-wiki/workflows/incremental.md`; validate patches before applying and advance the cursor only after all jobs succeed.

Raw durable user information belongs in `0. Inbox/Raw/` via `raw-inbox-memory`. Do not silently promote raw statements into curated knowledge pages.
