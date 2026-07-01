# Geo

A personal, local-first knowledge system for macOS: a native Swift app paired with a
24/7 agent that lives on the same machine and turns everything you capture into a
**personal brain that grows without bound**.

> **Personal, non-commercial project.** Geo is built and run for one person's own use.
> It is not a product, it is not for sale, and it is not intended for commercial
> deployment or distribution. See [Use & license](#use--license).

## What it is

Geo runs as two halves side-by-side on the same Mac:

- **The app** — a native macOS application written in **Swift / SwiftUI**. Local-first:
  your data is plain Markdown files on disk (`~/Library/Application Support/Geo/`), never
  a remote service. It gives you a notch UI, global-hotkey capture, screenshot OCR, a live
  knowledge graph, tasks, and a calendar.

- **hermes** — a **24/7 agent daemon** (a macOS LaunchAgent) with **full access to the
  machine**. It stays always-on, working in the background even when the app is closed: it
  bridges WhatsApp / Gmail / Telegram, runs scheduled prompts, dispatches coding subagents,
  and reads/writes the same Markdown vault directly over the native filesystem.

## The method: Zettelkasten, grown forever

Geo is built around the **Zettelkasten** methodology — atomic notes ("blocks") linked to
each other with `[[wikilinks]]`. Every capture becomes a block; every link thickens the
web. There is no folder hierarchy to maintain and no ceiling on size: the graph is designed
to **grow infinitely**, becoming denser and more useful the more you feed it. Because the
24/7 agent continuously files, links, and resurfaces notes on its own, the brain compounds
over time instead of rotting in an inbox.

- **Files are truth.** A block *is* its `.md` file — frontmatter properties plus inline
  `[[wikilinks]]` and `[[YYYY-MM-DD]]` day-links. Everything else (full-text search, the
  graph, tag and day maps) is a rebuildable cache derived from those files.
- **Local-first & private.** Your notes never leave the machine. The repo contains no
  personal data — the vault lives outside it, under `~/Library/Application Support/Geo/`.

## Architecture

```
Geo.app (Swift/SwiftUI)  ──writes──▶  ~/Library/Application Support/Geo/Blocks/**.md
   notch · capture · graph ·              (Markdown files = the single source of truth)
   tasks · calendar · OCR                            ▲
                                                     │ native filesystem
                                          hermes (LaunchAgent, 24/7 agent)
                                          WhatsApp · Gmail · Telegram · cron · subagents
```

More detail lives in [`CLAUDE.md`](CLAUDE.md), the ADRs under
[`Geo/docs/adr/`](Geo/docs/adr/), and [`INSTALL.md`](INSTALL.md).

## Build

```bash
xcodebuild build -scheme Geo -destination 'platform=macOS'
```

For a distributable DMG (ad-hoc signed; no Apple Developer account required):

```bash
bash Geo/scripts/build_dist.sh
```

## Use & license

This is a **personal, non-commercial** project, published for reference and for the
author's own use across machines. It is **not** a supported product: no warranty, no
commercial license, and no commitment to maintenance. Don't use it commercially.
See [`LICENSE`](LICENSE).
