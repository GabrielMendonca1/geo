# Geo

Personal, local-first knowledge system: a plain-Markdown vault (**`~/Vault/`**, edited via Obsidian) plus a set of satellite daemons that capture, index, and mirror everything — all over the native filesystem. No MCP, no HTTP API, no socket between components.

> **Personal, non-commercial project.** Geo is built and run for one person's own use.
> It is not a product, it is not for sale, and it is not intended for commercial
> deployment or distribution. See [Use & license](#use--license).

## Architecture

```
~/Vault/                              ← single source of truth
  Blocks/**.md       Zettelkasten (frontmatter id/type/status/layer/tags + [[wikilinks]])
  Tasks/<id>.json    one file per task
  Captures/          screenshot .png + .md OCR pairs (uploaded by GarimeCapture)
  Index/blocks.sqlite  rebuildable FTS cache (geo_indexer) — never authoritative
        ▲ native filesystem only
        │
geo_indexer (VM garime)     rebuilds the FTS index over the vault
GeoBridge                   tasks/terminal/chat → Garime (iOS) over Tailscale
GarimeCapture               daemon: screenshot + OCR → local spool → vault on the VM
GarimeWhisper               menu-bar dictation: hotkey → local whisper → paste
```

## Components (this repo)

| Dir | What it is |
|---|---|
| `hermes/` | Agent identity (`SOUL.md`) and vault scripts (`geo_indexer.py`, `context_scraping.py`) — the scripts' deployed copy runs on the VM garime |
| `GeoBridge/` | HTTP bridge (launchd `ai.geo.bridge`) serving tasks/terminal/chat to GeoMobile over the tailnet — see `GeoBridge/CONTRACT.md` |
| `Garime/` | iOS app (SwiftUI): unified Today, Chat, Agents, Terminal |
| `GeoCore/` | Swift package shared with the iOS app |
| `GarimeCapture/` | Swift daemon: screenshot + Vision OCR → durable local spool → `Captures/` in the vault on the VM garime. Never writes the local `~/Vault/` |
| `GarimeWhisper/` | Swift menu-bar dictation app: hotkey → local whisper → paste |
| `tests/` | `geo_time_contract.py` — time/timezone contract for `context_scraping` |

The former macOS app (Swift/SwiftUI) was **retired on 2026-07-04** — its code was removed from the repo (lives in git history). The old vault at `~/Library/Application Support/Geo/` is a frozen backup, read and written by nothing.

- **Files are truth.** A block *is* its `.md` file; everything else (FTS, graph, tag/day maps) is a rebuildable cache derived from those files.
- **Local-first & private.** Notes never leave the machine. The repo contains no personal data — the vault lives outside it, under `~/Vault/`.

Rules and deep dives: [`CLAUDE.md`](CLAUDE.md). Current work state: [`STATUS.md`](STATUS.md).

## Use & license

This is a **personal, non-commercial** project, published for reference and for the
author's own use across machines. It is **not** a supported product: no warranty, no
commercial license, and no commitment to maintenance. Don't use it commercially.
See [`LICENSE`](LICENSE).
