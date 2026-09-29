---
name: raw-inbox-memory
description: Save explicit or clearly durable user-provided information to Pasta's append-only 0. Inbox/Raw folder for future retrieval.
---

# Raw Inbox Memory

Write durable user-provided information to Pasta's `0. Inbox/Raw/` using the bundled `scripts/capture.py`. Preserve the user's wording. Do not write secrets, credentials, inferred sensitive traits, speculation, transient task details, or conversation dumps. If the capture fails, report that it was not saved.

Capture when the user asks to remember/save something. Before ending a session, review it for clearly useful user-stated preferences, decisions, commitments, relationships, routines, or durable project context that has not yet been captured. Keep each capture small; save the user's statement, not a transcript or an agent inference.

```bash
python3 "<skill-dir>/scripts/capture.py" \
  --kind <fact|preference|decision|commitment|relationship|routine|note> \
  --source <codex|claude> \
  --text '<verbatim user statement>'
```

The script resolves the vault from `--vault`, `PASTA_VAULT_PATH`, or `[general].vault_path` in `~/.pasta/config.toml`. It refuses obvious credential-like text by default.

Raw notes are evidence, not curated wiki pages. Leave synthesis and filing into knowledge folders to the later Pasta wiki maintenance workflow. A vault sync indexes raw notes for search; it does not file them into curated folders. Run `kb sync --source vault` only when the new capture needs to become searchable immediately.
