# brain-vault — Obsidian-like Markdown brains

A **brain** is a plain folder of Markdown notes — an Obsidian-style vault — that is
the **source of truth**. The 24/7 agent (hermes) reads, writes, and ingests these
files **directly on the filesystem**, so brains work whether or not the Geo app is
running. The Geo app is an optional viewer/indexer over the same folders.

## Where brains live

```
~/Geo/Brains/<name>/          # one folder per brain (override with $GEO_BRAINS_ROOT)
  .brain.json                 # meta: id, title, gist, nodes, sources
  index.md                    # the MOC — links every note
  sources/                    # original attached files (the backup of record)
  <slug>.md                   # atomic notes (flat, Obsidian-style)
```

Each note is plain Markdown with YAML frontmatter + `[[wikilinks]]`:

```markdown
---
type: literature
source: paper.pdf
chunk: <sha256>
created: 2026-06-03T…Z
---
# T-cell receptor signaling

The [[T cell]] receptor triggers a [[signaling cascade]] via [[ZAP-70]] …
```

Open `~/Geo/Brains/<name>/` in Obsidian or Finder — it's just files.

## CLI

```bash
python3 brain.py create <name> [--title "…"] [--gist "…"]
python3 brain.py list
python3 brain.py ingest <name> <file…> [--dry-run] [--model <id>]
python3 brain.py reindex <name>
```

- **ingest** copies each source into `sources/`, chunks it (~800 words, 80 overlap),
  distills each chunk into one atomic note, and rebuilds `index.md`. Idempotent —
  re-ingesting skips chunks already noted (SHA-256 of the chunk). With **no file args**
  it ingests everything in `sources/`. `--dry-run` writes raw chunks (no model, no auth).
- **Auth = your Claude Code account.** It reads the Claude Max OAuth token from the macOS
  Keychain (`Claude Code-credentials`, the store the `claude` CLI owns — run `claude` once
  to log in) and calls Haiku via `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`,
  bounded-concurrent (8-way). **No API key.** If `$ANTHROPIC_API_KEY` is set it switches to
  the cheaper async **Batch API** (OAuth lacks the `user:batch` scope, so batch needs a real key).
- PDF needs `pdftotext` (`brew install poppler`); `.txt`/`.md`/`.html` work natively.

## How the agent uses a brain (app-closed)

No special tooling — a brain is just files:

- **Read / search**: `Grep`/`Read` over `~/Geo/Brains/<name>/*.md`; follow `[[wikilinks]]`.
- **Curate (read-write)**: create or edit `.md` notes directly (the agent owns the vault).
- **Bulk ingest**: `python3 .../brain.py ingest <name> <files…>` for turning big sources
  into linked notes cheaply with Haiku.

This replaces the earlier MCP-routed, DB-as-truth design: the agent no longer needs the
Geo app's HTTP/MCP server to use a brain, and brains are no longer read-only.

## Geo app

The Swift app reads these folders to show a brain's notes + graph (a rebuildable
cache/index over the files — never the source of truth). _(In-app viewer rework pending —
see `Geo/conductor/tracks/brains/plan.md`.)_
