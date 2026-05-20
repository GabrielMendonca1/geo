# geo-worker

Remote Claude Code worker daemon for [Geo](../Geo). Runs on a VM (typically a sandboxed/ephemeral Linux box reachable over Tailscale), connects outbound to Geo's MCP TCP listener, authenticates with a token, and—on dispatch—spawns `claude` CLI sessions to do work on your behalf.

## Purpose

Geo dispatches work to remote workers so long-running coding sessions don't block your Mac. This daemon is the other half of that handshake:

- Connects out to Geo (no inbound ports required on the VM)
- Authenticates via a token registered in Geo's endpoint registry
- Receives `dispatch.run` requests and runs Claude Code
- Streams progress and completion back to Geo

v1 is a scaffold — it accepts dispatch requests and responds with mock progress/complete notifications. Real `claude` CLI spawning lands in v2.

## Install

```bash
cd geo-worker
npm install
```

v1 uses only Node built-ins, but `ws` is declared for the v2 WebSocket transport.

## Required environment variables

| Var                 | Required | Description                                                         |
| ------------------- | -------- | ------------------------------------------------------------------- |
| `GEO_HOST`          | yes      | Geo's MCP TCP listener host (typically a Tailscale IP)              |
| `GEO_PORT`          | yes      | TCP port Geo is listening on                                        |
| `GEO_AUTH_TOKEN`    | yes      | Auth token registered in Geo's endpoint registry                    |
| `WORKER_NAME`       | yes      | Human-readable worker name, e.g. `vector`                           |
| `WORKER_REPOS`      | no       | Comma-separated repo paths this worker can handle                   |
| `CLAUDE_CMD`        | no       | Command to invoke Claude Code CLI (default: `claude`)               |
| `SAFE_MODE`         | no       | `true`/`false` (default `false`). When `false`, Claude runs with `--dangerously-skip-permissions` |
| `GEO_WORKER_I_KNOW_WHAT_IM_DOING` | no | Set to `1` to override the root-outside-sandbox guard |

## Example `.env`

```env
GEO_HOST=100.64.1.23
GEO_PORT=8765
GEO_AUTH_TOKEN=replace-me-with-token-from-geo-settings
WORKER_NAME=vector
WORKER_REPOS=/home/worker/repos/geo,/home/worker/repos/arc
CLAUDE_CMD=claude
SAFE_MODE=false
```

## Running

```bash
npm start
```

Or during development:

```bash
npm run dev
```

## Deployment (recommended)

- Run inside a **sandboxed or ephemeral VM** (Docker, Podman, Firecracker, fly.io machines, a disposable Tailscale node, etc.). This daemon executes Claude Code with `--dangerously-skip-permissions` by default.
- Expose the VM to your Mac via **Tailscale** so Geo's MCP listener is only reachable on your tailnet.
- Register the worker in Geo under **Settings -> Voice Settings -> Endpoints** (UI in progress). Geo will mint the auth token and show you the host/port to configure here.
- Do not run on your host machine or on a shared VM without isolation.

## Safety warning

The daemon defaults to `SAFE_MODE=false`, which means dispatched Claude sessions run with `--dangerously-skip-permissions`. That is only acceptable inside a sandboxed, ephemeral, and untrusted-output-tolerant environment. On anything resembling a real box, set `SAFE_MODE=true` and accept the extra prompts, or don't run this at all.

The daemon also refuses to start as `root` outside a detected container unless you set `GEO_WORKER_I_KNOW_WHAT_IM_DOING=1`. Containers are detected via `/.dockerenv` or `/run/.containerenv`.

## Protocol

Line-delimited JSON-RPC 2.0 over a single TCP connection (matches Geo's `MCPFramer`). The worker sends `initialize` first; Geo responds with a session descriptor. After that, Geo sends `dispatch.run` / `dispatch.cancel` requests, and the worker emits `dispatch.progress` and `dispatch.complete` notifications.

## License

MIT
