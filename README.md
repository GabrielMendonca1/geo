# Garime Spirit

Personal, local-first system split by responsibility: human knowledge in **`~/Gabriel/`**, editable operational sources in **`~/Sistema/`**, and generated machine state in **`/mnt/garime/state/`**. The two human-editable trees sync through Syncthing; state stays outside Obsidian.

> **Personal, non-commercial project.** Garime Spirit is built and run for one person's own use.
> It is not a product, it is not for sale, and it is not intended for commercial
> deployment or distribution. See [Use & license](#use--license).

## Architecture

```
~/Gabriel/                          human Obsidian vault
  00 Entrada/ 10 Diário/ 20 Vida/ 30 Projetos/
  40 Conhecimento/ 50 Fontes/ 90 Arquivo/ _Anexos/
~/Sistema/                          operational Obsidian vault
  Pi/ (system prompt, skills, Omni prompts)  Claude/  Runbooks/
/mnt/garime/state/                  generated, outside Obsidian
  tasks/ index/ inbox/ health/ logs/ caches/
        ▲ native filesystem only
        │
geo_indexer (VM)     indexes human Markdown into state/index
GeoBridge            exposes task/health state and terminal over Tailscale
GarimeCapture        local screenshot/OCR archive, never writes either vault
GarimeWhisper        menu-bar dictation: hotkey → local whisper → paste
```

## Components (this repo)

| Dir | What it is |
|---|---|
| `hermes/` | Agent identity (`SOUL.md`) and vault scripts (`geo_indexer.py`, `context_scraping.py`) — the scripts' deployed copy runs on the VM garime |
| `GeoBridge/` | HTTP bridge (launchd `ai.geo.bridge`) serving tasks/terminal/chat to GeoMobile over the tailnet — see `GeoBridge/CONTRACT.md` |
| `Garime/` | iOS app (SwiftUI): unified Today, Chat, Agents, Terminal |
| `GeoCore/` | Swift package shared with the iOS app |
| `GarimeCapture/` | Swift daemon: screenshot + Vision OCR → durable local archive. Never writes `~/Gabriel/` or `~/Sistema/` |
| `GarimeWhisper/` | Swift menu-bar dictation app: hotkey → local whisper → paste |
| `tests/` | `geo_time_contract.py` — time/timezone contract for `context_scraping` |

The former macOS app (Swift/SwiftUI) was **retired on 2026-07-04** — its code was removed from the repo (lives in git history). The old vault at `~/Library/Application Support/Geo/` is a frozen backup, read and written by nothing.

- **Files are truth.** A block *is* its `.md` file; everything else (FTS, graph, tag/day maps) is a rebuildable cache derived from those files.
- **Local-first & private.** The repo contains no personal data; human and operational vaults live outside it under `~/Gabriel/` and `~/Sistema/`.

Rules and deep dives: [`CLAUDE.md`](CLAUDE.md). Current work state: [`STATUS.md`](STATUS.md).

## Use & license

This is a **personal, non-commercial** project, published for reference and for the
author's own use across machines. It is **not** a supported product: no warranty, no
commercial license, and no commitment to maintenance. Don't use it commercially.
See [`LICENSE`](LICENSE).
