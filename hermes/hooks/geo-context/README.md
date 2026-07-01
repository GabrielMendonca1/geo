# geo-context hook

Fires on `session:start` and `session:reset`.

Current file-native behavior:
- Reads User Profile, Memory, Interaction Protocol, Today, and pending task state directly from Gabriel's Geo vault under `~/Library/Application Support/Geo/`.
- Writes the fixed boot bundle to `~/.hermes/memories/MEMORY.md`.
- Hermes injects that memory file into future sessions/turns according to `~/.hermes/config.yaml`.
- The hook is TTL/hash gated, so unchanged or very recent fetches may not rewrite the file.

Important distinction:
- The hook is **not** semantic per-message RAG. It only injects a fixed boot bundle.
- Arbitrary project/person/life lookup should happen through the on-demand `geo_search_context` tool, registered by the `geo-search-tool` plugin. If that plugin is disabled, the agent may still have raw `geo_*` tools but loses the preferred cited context-search path.

Retired paths:
- No Geo HTTP API.
- No MCP/bridge/socket transport.
- No Keychain API token requirement.

Safe inspections:

```bash
cat ~/.hermes/status.json | jq
ls -la ~/.hermes/hooks/geo-context
cat ~/.hermes/memories/MEMORY.md | head
```
