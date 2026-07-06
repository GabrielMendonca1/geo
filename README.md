# Geo

Personal, local-first knowledge system: a plain-Markdown vault (**`~/GeoVault/`**, edited via Obsidian) plus **hermes**, a 24/7 agent LaunchAgent on the same Mac, and a set of satellite daemons that capture, index, and mirror everything — all over the native filesystem. No MCP, no HTTP API, no socket between components.

> **Personal, non-commercial project.** Geo is built and run for one person's own use.
> It is not a product, it is not for sale, and it is not intended for commercial
> deployment or distribution. See [Use & license](#use--license).

## Architecture

```
~/GeoVault/                              ← single source of truth
  Blocks/**.md       Zettelkasten (frontmatter id/type/status/layer/tags + [[wikilinks]])
  Tasks/<id>.json    one file per task
  Captures/          screenshot .png + .md OCR pairs (written by geocapture)
  Index/blocks.sqlite  rebuildable FTS cache (geo_indexer) — never authoritative
        ▲ native filesystem only
        │
hermes (LaunchAgent 24/7)   WhatsApp · Gmail · Telegram · cron · cc-dispatch
GeoBridge (launchd)         tasks/terminal/chat → GeoMobile over Tailscale
GeoCalendar / GeoCapture    daemons: task→EKEvent mirror · screenshot+OCR
```

## Components (this repo)

| Dir | What it is |
|---|---|
| `hermes/` | Geo layer over the upstream hermes-agent: `SOUL.md`, `PATCHES.md`, hooks (`geo-context`), scripts (`geo_indexer.py`, `context_scraping.py`), whatsapp-ingest, launch-agents |
| `hermes-extensions/` | Plugins: `geo-tools` (file-native `geo_*` vault tools + layer guard), geo-search-tool, whatsapp-confirm, brain-vault |
| `GeoBridge/` | HTTP bridge (launchd `ai.geo.bridge`) serving tasks/terminal/chat to GeoMobile over the tailnet — see `GeoBridge/CONTRACT.md` |
| `GeoMobile/` | iOS app (SwiftUI): unified Today, Chat, Agents, Terminal |
| `GeoCore/` | Swift package shared with GeoMobile |
| `GeoCalendar/` | Swift daemon mirroring vault tasks into Apple Calendar EKEvents (4 calendars by type) |
| `GeoCapture/` | Swift daemon: screenshot + OCR → `Captures/` in the vault |
| `tests/` | `geo_time_contract.py` — time/timezone contract for the geo-tools |

The former macOS app (Swift/SwiftUI) was **retired on 2026-07-04** — its code was removed from the repo (lives in git history). The old vault at `~/Library/Application Support/Geo/` is a frozen backup, read and written by nothing.

- **Files are truth.** A block *is* its `.md` file; everything else (FTS, graph, tag/day maps) is a rebuildable cache derived from those files.
- **Local-first & private.** Notes never leave the machine. The repo contains no personal data — the vault lives outside it, under `~/GeoVault/`.

Rules and deep dives: [`CLAUDE.md`](CLAUDE.md). Current work state: [`STATUS.md`](STATUS.md).

## Use & license

This is a **personal, non-commercial** project, published for reference and for the
author's own use across machines. It is **not** a supported product: no warranty, no
commercial license, and no commitment to maintenance. Don't use it commercially.
See [`LICENSE`](LICENSE).
