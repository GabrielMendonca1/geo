# geo-context hook

Fires on `session:start` and `session:reset`. Reads the live Memory / User-Profile / Interaction Protocol / Today state from Gabriel's Geo macOS app via its HTTP API on `127.0.0.1:<port>` (port discovered from `~/Library/Application Support/Geo/api.json`, bearer token read from Keychain at `service=geo-api-bootstrap, account=hermes-hook`). Optionally summarizes Today's record with Claude Haiku, then writes the consolidated result to `~/.hermes/memories/MEMORY.md`. Hermes's own memory-injection pipeline picks that file up at session start so the agent always begins a conversation with current real-world context.

Requirements:
- Geo.app must be running (api.json's pid must be live).
- `hermes-hook` Keychain entry must exist with a Geo API token.
- `hermes auth add anthropic --type oauth` for Haiku summarization.

Safe to leave installed forever — silently no-ops when Geo.app is closed or the token is missing.
