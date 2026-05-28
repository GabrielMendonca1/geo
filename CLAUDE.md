# Geo

macOS productivity hub (Swift/SwiftUI, local-first) + the hermes LaunchAgent that reads/writes Geo's data over MCP. Captures, organizes, transcribes; bridges WhatsApp / Gmail / Telegram and dispatches subagents.

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
│  │            Calendar · Agent · Nano · Settings · About    │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  Stores (@ObservableObject + Combine, singletons)        │  │
│  │  BlocksStore · TasksStore · TagStore · DayStore · Nav    │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  Infra: GRDB (SQLite) · Vision OCR · CGEventTap ·        │  │
│  │         FileWatcher · AI · MCP server (TCP + stdio)      │  │
│  │       │                                                  │  │
│  │       ▼                                                  │  │
│  │  ~/Library/Application Support/Geo/                      │  │
│  │   Blocks/*.md  Tasks/*.md  tags.json  days.json          │  │
│  └────┬──────────────────────────┬──────────────────────────┘  │
│       │ MCP stdio                │ MCP stdio                   │
│       ▼                          ▼                             │
│  ┌──────────────────┐   ┌──────────────────────────────────┐   │
│  │ geo-mcp-bridge   │   │  hermes  (LaunchAgent, ~/.hermes)│   │
│  │ Swift binary     │   │  • WhatsApp/Gmail/Telegram bridge│   │
│  │ thin MCP bridge  │   │  • cron prompts                  │   │
│  └──────────────────┘   │  • claude-code-lane (CC workers) │   │
│                         │  • api_server HTTP+SSE @ 8642    │   │
│                         └──────────────────────────────────┘   │
│                                  ▲                             │
│                          Nano in-app pane talks to it          │
│                          via HermesHTTPTransport (SSE)         │
└────────────────────────────────────────────────────────────────┘
```

## Layout (repo root)

```
Geo/                          macOS app source (Swift/SwiftUI) — see "Geo app" below
Geo.xcodeproj/                Xcode project
geo-mcp-bridge/               Swift binary, thin MCP bridge for the macOS app
hermes/                       hermes daemon config (config.yaml, SOUL.md, memories/, install.sh)
hermes-extensions/            custom MCP plugins + worker daemons that ship with hermes
  claude-code-lane/           Plugin + LaunchAgent daemon — spawns `claude` CLI as kanban workers
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

Layout in this repo:

```
hermes/
  config.yaml      gateway config (api_server, connectors, cron)
  SOUL.md          system prompt / identity
  memories/        long-term memory blocks
  install.sh       drops the LaunchAgent plist into ~/Library/LaunchAgents and starts it
hermes-extensions/
  claude-code-lane/    Hermes plugin (`claude_code_run` MCP tool) + LaunchAgent daemon
                       (`ai.hermes.claude-code-lane`). Spawns `claude -p` instances in
                       arbitrary directories as kanban workers (assignee=claude-code).
                       Has its own `install.sh`; see hermes-extensions/claude-code-lane/README.md.
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

The `dispatch-subagent` MCP tool is how hermes hands off long-running work to Claude Code subagents — replacing the old `pi`-spawning code in `AgentWorkspaceManager`. The Swift manager keeps a hybrid `dispatchMode` flag (`legacyPi` vs `hermesTool`) during the migration window.

## geo-mcp-bridge

Swift binary (`main.swift` + `build.sh`) — thin MCP bridge for the macOS app. Build:

```bash
cd geo-mcp-bridge && ./build.sh
```

## AI pane (`Geo/Features/Agent/`)

Kanban-over-CLI. `AgentWorkspaceManager` (Swift actor) polls a tracker (`linear` or `local` Geo blocks with `symphony: true` frontmatter) and dispatches eligible issues into per-issue workspaces under `~/.symphony/workspaces/`. The hybrid `dispatchMode` flag chooses between the legacy `pi` CLI path and the new `hermes-extensions/dispatch-subagent` MCP tool. Provider is derived from `NanoProviderStore.current`.

Frontmatter writes go through `BlocksStore.FrontmatterMutator` with a monotonic `frontmatter_version` counter to avoid lost updates between the app and hermes.

## The hard rules (app)

- **Sandbox is OFF** (`com.apple.security.app-sandbox = false`). Required for: arbitrary screenshot dir watching, launching subagents, CGEventTap accessibility. If moving to App Store this must change.
- **State is singleton stores**, not view-local. New persisted state → new Store, not a `@State` somewhere.
- **TDD**: tests track in `Geo/conductor/tracks/<track>/plan.md`; tech-stack changes go in `Geo/conductor/tech-stack.md`.
- **Commit format**: `<type>(<scope>): <description>` — `feat fix docs style refactor test chore`.

## Cross-cutting

- The macOS app is the **only** thing that owns the data on disk. Hermes reaches Geo data via MCP (through `geo-mcp-bridge`), not by reading files directly.
- Extending hermes capabilities = adding an MCP tool under `hermes-extensions/`, not bypassing the bridge.
