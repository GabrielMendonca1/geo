# Geo

macOS productivity hub (Swift/SwiftUI, local-first) + the hermes LaunchAgent that reads/writes Geo's data over the native filesystem on the same Mac (MCP and the localhost HTTP API both retired as the data contract). Captures, organizes, transcribes; bridges WhatsApp / Gmail / Telegram and dispatches subagents.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     Geo system (this repo)                     │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Geo.app   (Swift / SwiftUI, macOS, local-first)         │  │
│  │                                                          │  │
│  │  Notch UI · FloatingShelf · Main Window · Global hotkey  │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  Features: Blocks · Tasks · Tags · Graph · Capture ·     │  │
│  │            Calendar · Nano · Settings · About            │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  Stores (@ObservableObject + Combine, singletons)        │  │
│  │  BlocksStore · TasksStore · TagStore · DayStore · Nav    │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  Infra: GRDB (SQLite) · Vision OCR · CGEventTap ·        │  │
│  │         FileWatcher · AI                                 │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  ~/Library/Application Support/Geo/   (files are truth)  │  │
│  │   Blocks/<Layer>/**.md (frontmatter Properties +         │  │
│  │     inline [[wikilinks]] & [[YYYY-MM-DD]] day-links)     │  │
│  │   Tasks/*.md · tags.json (colors) · days.json            │  │
│  │   Index/blocks.sqlite (rebuildable cache, derived)       │  │
│  └──────────────────────────┬─────────────────────────────┘      │
│                              │ native FS only: reads via RO      │
│                              ▼ Index/blocks.sqlite, FS writes    │
│                       ┌──────────────────────────────────┐       │
│                       │  hermes  (LaunchAgent, ~/.hermes) │      │
│                       │  • WhatsApp/Gmail/Telegram bridge │      │
│                       │  • cron prompts                   │      │
│                       │  • cc-dispatch (CC workers)       │      │
│                       └──────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────┘
```

## Layout (repo root)

```
Geo/                          macOS app source (Swift/SwiftUI) — see "Geo app" below
Geo.xcodeproj/                Xcode project
hermes/                       hermes daemon config (config.yaml, SOUL.md, bin/cc-dispatch, install.sh)
hermes-extensions/            custom plugins + worker daemons that ship with hermes
  brain-vault/                file-native brain vault tools (see Brains track) · geo-tools/ · …
LICENSE
```

## Geo app (`Geo/`)

```
App/         @main, composition, Notch UI, entitlements
Features/    feature modules (each = Data + Domain + UI)
Shared/      DesignSystem · Infrastructure · Navigation · Platform · Tags
Utilities/   GeoStyle · ResponsiveLayout · WindowReflection
Extensions/  Bundle+, NSWindow+, ProcessInfo+
Tests/       XCTest, target >80% coverage
docs/        ADRs + architecture notes
conductor/   tracks/<track>/plan.md — TDD task tracking
```

Build / test:

```bash
xcodebuild build  -scheme Geo -destination 'platform=macOS'
xcodebuild test   -scheme Geo -destination 'platform=macOS'
xcodebuild clean  -scheme Geo
```

Key services: `OCRService` (Vision) · `GlobalHotkeyManager` (CGEventTap) · `PermissionRegistry` · `DatabaseService` (GRDB) · `IndexCoordinator` · `DayManager` (midnight transitions).

Design system: Geo Blue `#0055FF` · SF Pro · SF Symbols · dark mode required · Apple HIG. Details in `Geo/conductor/product-guidelines.md`.

## hermes

Hermes is the 24/7 agent daemon that replaced geo-claw. It runs as a macOS LaunchAgent (`ai.hermes.gateway`), keeps WhatsApp / Gmail / Telegram online, runs cron prompts, and exposes an HTTP+SSE api_server on `127.0.0.1:8642` that the in-app Nano pane talks to via `HermesHTTPTransport`.

**Inference.** The gateway runs on **`gpt-5.5` via the `openai-codex` provider** (sub-backed; `config.yaml` `model.provider`/`model.default`). Running the gateway on Claude (Max-OAuth) was tried and abandoned: Anthropic meters **any tool-bearing request on a Claude subscription OAuth token to the empty extra-usage bucket** → `400 out-of-extra-usage`, by design (confirmed by the hermes maintainer in issue #28849, and #15080/#10575). The gateway always carries tools, so it can't run free on the sub. The standalone scripts (whatsapp-extractor Opus decide, day/close briefings, geo-context Haiku hook) DO use Claude on the sub via the Keychain `Claude Code-credentials` token (`model.full`/`model.nano`) — because those calls are **tool-free** and bill against the included quota. `model.default` must stay set (`gpt-5.5`) or agent-mode crons fail with an empty-model Codex error. See memory `hermes-model-provider` for the full investigation.

Layout in this repo:

```
hermes/
  config.yaml      gateway config (api_server, connectors, cron)
  SOUL.md          system prompt / identity
  bin/cc-dispatch  spawns detached `claude` workers, tracked under ~/.hermes/dispatches/<id>/
  memories/        long-term memory blocks
  install.sh       drops the LaunchAgent plist into ~/Library/LaunchAgents and starts it
hermes-extensions/
  geo-tools/       Hermes plugin exposing Geo as file-native `geo_*` tools (vault FS + RO sqlite index)
  brain-vault/     file-native brain vault tools (see Brains track)
```

Install:

```bash
bash hermes/install.sh        # drops plist + starts the gateway
launchctl list ai.hermes.gateway   # verify it's running
```

Runtime layout (managed by hermes, NOT in this repo):

```
~/.hermes/
  .env                        API_SERVER_KEY, connector creds
  SOUL.md                     editable runtime copy
  memories/                   runtime memories
  db/hermes.sqlite            conversations + cron state
  logs/gateway.log            ND-JSON daemon log
```

In-app surface:
- Nano pane (`Geo/Features/Nano/`) reads hermes status, tails the log, shows cron tiles, and routes chat through `HermesHTTPTransport`.
- Settings → Hermes (`NanoHermesSettingsView`) installs the daemon, opens SOUL/.env, surfaces the API key, and rotates the MCP endpoint token.

Hermes hands off bounded coding work to Claude Code with `~/.hermes/bin/cc-dispatch "<brief>" --dir <abs> [--model <id>] [--title <t>]`. It spawns `claude -p <prompt> --output-format stream-json --dangerously-skip-permissions` detached in the workspace dir and tracks each run as files under `~/.hermes/dispatches/<id>/` (`status` = running|done|failed · `log.jsonl` live stream · `result.json` final response+cost+session_id). The agent reads those files to see what its workers are doing — there is no kanban lane and no `claude_code_run` MCP tool (both retired 2026-06-05). Run several at once by calling it repeatedly with different `--dir`. Documented in `hermes/SOUL.md`; deployed by `hermes/install.sh` (synced from `hermes/bin/`).

## Storage model (files are truth)

A block **is** its `.md` file. The file holds the whole truth: frontmatter Properties (`id`, `type`, `status`, `layer`, `tags`, `full_width` — omitted when false) plus inline `[[wikilinks]]` and `[[YYYY-MM-DD]]` day-links in the body. The app **derives** everything else — FTS, the graph, the tag-map (`block_tags`), and the day-map (`block_days`) — into `Index/blocks.sqlite`, which is a **rebuildable cache, never authoritative**: corruption is fixed by re-deriving from the files (FileWatcher → `BlockChangeReconciler` → `rebuildIndex`). See `Geo/docs/adr/ADR-0002-files-are-truth-vault-native-storage.md` for the full model, the folder→layer map (`Voce`/`Agente`/`Revisao`/`Compartilhado` ASCII slugs), and the phased (default-OFF gated) migration.

Zero-data-loss: `days.json`, `tags.json` (full schema incl. colors/membership), and the SQLite metadata columns (`layer`/`tagId`/`dayId`/`isFullWidth`) are **kept as rebuildable caches / fallbacks** for blocks whose Properties are not yet inlined. Phase 1–3 reads are frontmatter/derived-preferred *with* a fallback to SQLite/`days.json`. The retired `.blocks-metadata.json` sidecar (Phase 0) is gone from the runtime; SQLite is its replacement cache. The hard cutover (dropping the fallback columns) is **deferred behind a default-OFF gate** (`geo.migration.filesAreTruth.enabled`); `FilesAreTruthMigrationRunner` is the single deliberate completion path — it backs up the whole `Geo/` dir first, aborts if the index is empty, then runs the idempotent reinject→layer→tags→day-links backfills. `Index/blocks.sqlite` is the sole live cache; `geo-index.db` (stale FTS), the 0-byte `Index/blocks.db`, and the 0-byte `geo.sqlite` are orphan disk artifacts with no code references (clean manually).

`frontmatter_version` is **demoted**: it is still written (harmlessly, monotonic) but is no longer treated as cross-process coordination — concurrency is a non-issue (single-user serial app), and all readers tolerate its absence (→ 0). `FrontmatterMutatorActor` only serializes same-block writes in-process; it is not a multi-writer lock.

> Historical: an in-app AI/Agent pane (`Geo/Features/Agent/`) used to drive its own kanban with `symphony: true` frontmatter and `~/.symphony/workspaces/`. Removed in favor of out-of-app `claude` dispatch (`hermes/bin/cc-dispatch`), which owns the worker-spawning role entirely outside the app. Inert `symphony: true` keys in existing blocks and the `~/.symphony/workspaces/` tree on disk are leftover user data — code stops reading them but they survive until cleaned manually.

## The hard rules (app)

- **Sandbox is OFF** (`com.apple.security.app-sandbox = false`). Required for: arbitrary screenshot dir watching, launching subagents, CGEventTap accessibility. If moving to App Store this must change.
- **State is singleton stores**, not view-local. New persisted state → new Store, not a `@State` somewhere.
- **TDD**: tests track in `Geo/conductor/tracks/<track>/plan.md`; tech-stack changes go in `Geo/conductor/tech-stack.md`.
- **Commit format**: `<type>(<scope>): <description>` — `feat fix docs style refactor test chore`.

## Cross-cutting

- The macOS app **owns deriving the indexes** (FTS/graph/tag-map/day-map → `Index/blocks.sqlite`); the `.md` files are the truth both the app and hermes share. MCP **and** the localhost HTTP API are both retired as the data contract (ADR-0002 §1.2/§8) — Geo serves nothing over a socket anymore.
- Hermes runs side-by-side on the same Mac and reaches Geo **purely through the filesystem**: it reads the RO `Index/blocks.sqlite` (falling back to a file scan) and raw-FS-writes the layers it owns (`Agente`/`Revisao`/`Compartilhado`) — never `Voce/` (enforced by the plugin's `guard.py` + FileWatcher quarantine).
- The tool surface is **native FS ops + KEEP-COMPUTE**: block/task writers mutate `.md`/`Tasks` files directly; read / search / dedup / bm25 / graph tools query the RO sqlite index.
- Extending hermes capabilities = adding a tool under `hermes-extensions/` or a native FS op, not re-centralizing on any in-app server.
