# Geo

Personal, local-first macOS knowledge hub: a native **Swift/SwiftUI** app plus **hermes**, a 24/7 agent LaunchAgent on the same Mac. Both read/write the **same Markdown vault directly over the filesystem — no socket, no MCP, no HTTP between them**. The app captures, organizes, transcribes, and renders a Zettelkasten graph; hermes bridges WhatsApp/Gmail/Telegram, runs cron prompts, and dispatches Claude Code subagents.

```
Geo.app (SwiftUI)  ──derives──▶  Index/blocks.sqlite   (rebuildable cache)
  notch · capture · graph · tasks · calendar · OCR · Nano
        │ writes .md
        ▼
~/Library/Application Support/Geo/Blocks/**.md   ← single source of truth
        ▲
        │ native filesystem only (no socket)
hermes (LaunchAgent)   WhatsApp · Gmail · Telegram · cron · cc-dispatch
```

This file is the source of truth for the architecture. Deep dives on demand: storage model → `Geo/docs/adr/ADR-0002-files-are-truth-vault-native-storage.md`; install + macOS permissions → `INSTALL.md`; hermes runtime → `hermes/config.yaml` + `hermes/SOUL.md`.

## Build / run / test

Scheme is `Geo` (auto-generated from the target; there is no checked-in `.xcscheme`).

```bash
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' build
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' test
xcodebuild clean -scheme Geo
```

- **Tests run as-is.** The Debug config sets `ENABLE_DEBUG_DYLIB = NO` + `ENABLE_HARDENED_RUNTIME = NO` (in `project.pbxproj`) so the XCTest host launches — don't re-add those as command-line flags.
- **To actually RUN the app, build Release and copy it in** — a Debug build crashes on launch (`@rpath/Geo.debug.dylib`):
  ```bash
  export DEVELOPER_DIR="$HOME/Applications/Xcode-beta.app/Contents/Developer"
  SRC=$(xcodebuild -scheme Geo -configuration Release -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR /{print $3; exit}')
  ditto "$SRC/Geo.app" /Applications/Geo.app && open /Applications/Geo.app
  ```
- **Distributable DMG** (ad-hoc signed, no Apple account needed): `bash Geo/scripts/build_dist.sh`. Notarize path: `Geo/scripts/notarize.sh` (see `INSTALL.md`).
- **Verify UI changes by running the real app**, not by tests alone — the editor keystroke path has invariants the suite can't catch (see Hard rules).

## Hard rules

- **Files are truth.** A block *is* its `.md` file. `Index/blocks.sqlite` (FTS + graph + `block_tags` + `block_days`) is a **rebuildable cache, never authoritative** — corruption is fixed by re-deriving from files (FileWatcher → `BlockChangeReconciler` → rebuild). Only `tags.json` (tag colors) and `days.json` survive as small central caches/fallbacks; the `.blocks-metadata.json` sidecar is retired.
- **Sandbox is OFF** (`com.apple.security.app-sandbox = false`). Required for screenshot-dir watching, launching subagents, and the `CGEventTap` hotkey. Moving to the App Store would force this to change.
- **State lives in singleton stores**, not views. New persisted state → a new Store (`@MainActor ObservableObject`), never a stray `@State`.
- **hermes writes only its layers.** It may raw-FS-write `Agente`/`Revisao`/`Compartilhado` blocks, **never `Voce/`** (the user's) — enforced by `hermes-extensions/geo-tools/guard.py` + FileWatcher quarantine.
- **Editor keystroke invariants** (`Geo/Features/Blocks/UI/BlockEditor.swift`): the marked-text guard, the `editGeneration` bump, and the `isApplyingTransaction` mask are load-bearing. Drop any one and the editor freezes on specific inputs *while still passing the suite*. Verify editor edits by running the app.
- **TDD.** Track work in `Geo/conductor/tracks/<track>/plan.md`; tech-stack changes go in `Geo/conductor/tech-stack.md`.
- **Commit format:** `<type>(<scope>): <description>` — `feat fix docs style refactor test chore`.

## App layout (`Geo/`)

```
App/         @main, composition, Notch UI, entitlements
Features/    feature-first modules (each = Data + Domain + UI):
             Blocks Tasks Calendar Capture Graph Brains Nano
             FloatingShelf Home Settings About Onboarding
Shared/      DesignSystem · Infrastructure (GRDB) · Navigation · Platform · Tags · Support
Utilities/ Extensions/   small cross-cutting helpers
Tests/       XCTest
docs/        ADRs (adr/) + architecture notes
conductor/   product/process tracks, tech-stack, product guidelines
scripts/     build_dist.sh · notarize.sh · dev
```

Key services: `OCRService` (Vision) · `GlobalHotkeyManager` (CGEventTap) · `PermissionRegistry` · `DatabaseService`/`IndexCoordinator` (GRDB) · `DayManager` (midnight transitions).

Design system: Geo Blue `#0055FF` · SF Pro · SF Symbols · dark mode · Apple HIG. Details in `Geo/conductor/product-guidelines.md`.

## Storage model

The `.md` file holds the whole truth: frontmatter Properties (`id`, `type`, `status`, `layer`, `tags`, `full_width` — omitted when false) plus inline `[[wikilinks]]` and `[[YYYY-MM-DD]]` day-links in the body. The app **derives** everything else (FTS, graph, tag-map, day-map) into `Index/blocks.sqlite`. Layer is a frontmatter property **today — the vault is flat**; ADR-0002 specifies a future folder-per-layer split (`Voce`/`Agente`/`Revisao`/`Compartilhado` — ASCII slugs on disk, accented display names) and `guard.py` already checks the folder segment so it survives that split. `frontmatter_version` is still written (monotonic) but is **not** a coordination lock: this is a single-user serial app and all readers tolerate its absence.

## hermes

24/7 agent daemon (LaunchAgent `ai.hermes.gateway`) that keeps WhatsApp/Gmail/Telegram online and runs cron prompts. Install: `bash hermes/install.sh`, then `launchctl list ai.hermes.gateway` to verify.

```
hermes/
  config.yaml       platforms · model · approvals · quick_commands — live source of truth for runtime behavior
  SOUL.md           system prompt / identity
  bin/cc-dispatch   spawns detached `claude` workers → ~/.hermes/dispatches/<id>/
  install.sh        drops the plist into ~/Library/LaunchAgents and starts the gateway
hermes-extensions/  plugins: geo-tools (file-native geo_* vault tools + RO sqlite index + guard.py),
                    geo-search-tool, whatsapp-confirm, brain-vault
```

Runtime state (managed by hermes, NOT in repo): `~/.hermes/` — `.env`, `SOUL.md`, `memories/`, `db/hermes.sqlite`, `logs/gateway.log`, `dispatches/`.

**In-app surface (Nano).** `Geo/Features/Nano/` reads hermes state **straight from the filesystem**: `HermesStatusService` (status + log tail) and `HermesKanbanService` (`~/.hermes/dispatches/`). There is no `HermesHTTPTransport` — the app never opens a socket to hermes. Settings → Hermes (`NanoHermesSettingsView`) installs the daemon and surfaces `API_SERVER_KEY` from `~/.hermes/.env`.

**Inference.** The gateway runs on **`gpt-5.5` via the `openai-codex` provider** (native tool_calls + streaming, one HTTP call per hop); the chat lane is latency/tool-reliability-bound, not intelligence-bound. Heavy/coding work goes to **Claude via `cc-dispatch`** workers. `model.default` must stay non-empty (agent-mode crons resolve `job.model → model.default`). `model.full`/`model.nano` (`claude-opus-4-8`/`claude-haiku-4-5`) are used **only by tool-free standalone scripts** via the Max-sub OAuth Keychain token, billing the included quota. Running the *gateway* on Claude currently 400s ("out of extra usage") — the Max sub's included quota is depleted/contended on this Mac, so switching needs funded extra usage. The `claude-code-local` `claude -p` proxy lane is retired. Full current rationale: `hermes/config.yaml` `model:` block.

**cc-dispatch.** `~/.hermes/bin/cc-dispatch "<brief>" --dir <abs> [--model <id>] [--title <t>]` spawns `claude -p … --output-format stream-json --dangerously-skip-permissions` detached, tracked as files under `~/.hermes/dispatches/<id>/` (`status` · `log.jsonl` · `result.json`). Run several at once with different `--dir`. There is no kanban lane and no `claude_code_run` MCP tool.

> Historical: the in-app Agent pane (`symphony: true` frontmatter, `~/.symphony/`) and `geo-claw` were removed — worker-spawning is now entirely out-of-app via `cc-dispatch`. Inert `symphony:` keys in old blocks are leftover user data.
