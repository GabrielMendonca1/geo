# Symphony Conformance Posture

Geo treats the Symphony specification as the orchestrator contract and keeps two documented extensions at the integration edge.

## Core Contract

The orchestrator dispatches normalized issues, creates deterministic per-issue workspaces, runs lifecycle hooks, enforces active and terminal states from `WORKFLOW.md`, retries with bounded backoff, and keeps operator-visible runtime state.

`tracker.kind: linear` is the spec tracker. `tracker.kind: local` is a Geo extension that must emit the same normalized issue model as Linear.

`agents.runtime: pi` is the only runner. It spawns the `pi` CLI (`@earendil-works/pi-coding-agent`) per turn with `--mode json`, resumes via `--session <id>` captured from pi's first-line `session` event, and selects provider from `NanoProviderStore` (`claude` → `anthropic`, `codex` → `openai`). In-agent MCP access is provided by the `geo-mcp` pi extension (see repo-root `CLAUDE.md`); pi has no native MCP flag.

## Trust And Approval

Geo runs in a high-trust local desktop posture:

- Command approvals are auto-approved.
- File change approvals are auto-approved.
- User-input-required events fail the current turn.
- Sandbox policy is the pi default; configure via `~/.pi/agent/settings.json` if needed.

## Deliberate Non-Goals

The standalone Symphony CLI actor is not implemented because Geo hosts the service inside the app process.

The optional HTTP dashboard extension is not implemented; Geo's Agent pane is the status surface.

## Cleanup Direction

The orchestration layer should depend on tracker and runner abstractions only. Local issue editing belongs to the local tracker adapter and UI. Pi process details belong to the runner adapter. Project discovery, JSON side stores, and runtime-specific branches inside the orchestrator should be removed as the adapter seams land.
