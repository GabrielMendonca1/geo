# Geo

macOS productivity hub (Swift/SwiftUI, local-first) + a fleet of agents that read/write Geo's data over MCP. Captures, organizes, transcribes; dispatches Claude sessions to a remote VM and runs a 24/7 WhatsApp/Gmail agent.

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
│  │            Calendar · Agent · Home · Settings · About    │  │
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
│  └────┬────────────────────────┬────────────────────────┬───┘  │
│       │ MCP stdio              │ MCP stdio              │ MCP  │
│       ▼                        ▼                        ▼ TCP  │
│  ┌──────────────────┐   ┌────────────────────┐  (auth token,   │
│  │ geo-mcp-bridge   │   │     geo-claw       │   over          │
│  │ Swift binary     │   │ Node/TS, macOS     │   Tailscale)    │
│  │ thin MCP bridge  │   │ LaunchAgent (24/7) │                 │
│  └──────────────────┘   │ • WhatsApp/Baileys │                 │
│                         │ • Gmail OAuth      │                 │
│                         │ • Claude API agent │                 │
│                         │ self-DM hard guard │                 │
│                         └────────────────────┘                 │
│                                                                │
│                 ┌──────────────────────────────────────────┐   │
│                 │ geo-worker  (Node, runs on a remote VM)  │   │
│                 │ Connects out to Geo's MCP TCP listener,  │   │
│                 │ auths with token, receives dispatch.run, │   │
│                 │ spawns `claude` CLI, streams progress.   │   │
│                 │ v1 = scaffold (mock notifications)       │   │
│                 └──────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

## Layout (repo root)

```
Geo/                 macOS app source (Swift/SwiftUI) — see "Geo app" below
Geo.xcodeproj/       Xcode project
geo-claw/            24/7 WhatsApp + Gmail Claude agent (Node/TS, macOS LaunchAgent)
geo-mcp-bridge/      Swift binary, thin MCP bridge for the macOS app
geo-worker/          Remote Claude Code worker daemon (Node, runs on a VM)
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

## geo-claw

24/7 always-on Claude agent (WhatsApp via Baileys + Gmail OAuth) running as macOS LaunchAgent. Calls Geo's MCP tools. Node 20+.

```bash
cd geo-claw
npm install && npm run build
npm run dev    # tsx watch src/index.ts
```

Env: `ANTHROPIC_API_KEY`, `GEO_CLAW_GOOGLE_CLIENT_ID`, `GEO_CLAW_GOOGLE_CLIENT_SECRET`.

**Hard rule**: only sends WhatsApp messages to the chat with your own number (self-DM). Reads from any chat. Don't relax this guard.

## geo-mcp-bridge

Swift binary (`main.swift` + `build.sh`) — thin MCP bridge for the macOS app. Build:

```bash
cd geo-mcp-bridge && ./build.sh
```

## geo-worker

Remote Claude Code worker daemon. Runs on a Linux VM (typically over Tailscale), connects **out** to Geo's MCP TCP listener (no inbound ports needed), auths with a token registered in Geo's endpoint registry, receives `dispatch.run` and spawns `claude` CLI.

```bash
cd geo-worker
npm install
npm start          # or npm run dev (--watch)
```

v1 = scaffold returning mock progress/complete. Real CLI spawn lands in v2.

## The hard rules (app)

- **Sandbox is OFF** (`com.apple.security.app-sandbox = false`). Required for: arbitrary screenshot dir watching, launching `claude`/`codex` via `AgentWorkspaceManager`, CGEventTap accessibility. If moving to App Store this must change.
- **State is singleton stores**, not view-local. New persisted state → new Store, not a `@State` somewhere.
- **TDD**: tests track in `Geo/conductor/tracks/<track>/plan.md`; tech-stack changes go in `Geo/conductor/tech-stack.md`.
- **Commit format**: `<type>(<scope>): <description>` — `feat fix docs style refactor test chore`.

## Cross-cutting

- The macOS app is the **only** thing that owns the data on disk. Satellites (`geo-claw`, `geo-worker`) reach data via MCP, not by reading files directly.
- `geo-worker` is a planned remote-agent fleet (v1 scaffolded). When extending, do it via MCP tools the app already exposes — don't bypass.
