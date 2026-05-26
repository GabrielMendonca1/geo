# dispatch-subagent

MCP stdio server that exposes a single tool, `mcp_hermes_dispatch_subagent`, which spawns `pi` (the `@earendil-works/pi-coding-agent` CLI) per turn against an issue workspace and streams its JSON events back. It is the Python port of the spawn loop that previously lived in `Geo/Features/Agent/Data/AgentWorkspaceManager.swift` (see `spawnPi` ~L1860 and `applyPiStreamLine` ~L1948), with two upgrades: (1) a `target` argument so the same tool dispatches either to the local machine or to a configured SSH host, and (2) debounced frontmatter writes — the previous implementation stamped on every line, this one batches per-block for 500 ms before emitting a single `mcp_geo_update_block`. The dispatcher keeps `hermes_session_id` (the dispatch handle, a UUIDv7 it generates) and `pi_session_id` (captured from pi's first `type:"session"` event) as two distinct fields and never conflates them; the latter is what gets stamped into the issue block's `symphony_session_id` frontmatter for `pi --session <id>` resume on subsequent turns.

## Install

```bash
cd hermes-extensions/dispatch-subagent
pip install -e .
```

Then add it to `~/.hermes/config.yaml` under `mcp_servers:`:

```yaml
mcp_servers:
  geo:
    command: /Users/biel/ARC/Forge/Geo/geo-mcp-bridge/geo-mcp-bridge
    args: []
    env: {}
  dispatch_subagent:
    command: dispatch-subagent
    args: []
    env: {}
```

Remote targets (optional) live in `~/.hermes/dispatch-targets.yaml`:

```yaml
targets:
  - name: hetzner-01
    host: hetzner-01.tail-scale.ts.net
    user: biel
    key_path: ~/.ssh/id_ed25519
    pi_path: /home/biel/.local/bin/pi
    workspace_root: /home/biel/.symphony/workspaces
```

Caps (`/triad` commitments): local semaphore = 8, remote semaphore = 3, per-process stdout deque = 1000 lines, frontmatter debounce = 500 ms, hard kill = 30 min wallclock, capacity wait = 30 s.
