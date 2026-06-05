# hermes upstream patches (re-apply after `hermes update`)

`hermes` is upstream (`NousResearch/hermes-agent`), installed at `~/.hermes/hermes-agent/`
and **not vendored** in this repo. A `hermes update` overwrites it, dropping the local
forks below. Re-apply each after updating, then
`launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`.

---

## 1. Clean first-party User-Agent on the OAuth inference path

**File:** `~/.hermes/hermes-agent/agent/anthropic_adapter.py`
**Function:** `build_anthropic_client`, the `_is_oauth_token(api_key)` branch (~line 752).

**Why:** The gateway runs primary on `anthropic/claude-opus-4-8` against Gabriel's
Claude Max sub via first-party OAuth. Upstream builds the Claude Code identity, but the
OAuth branch set `default_headers` with a **lowercase** `"user-agent"` key. The Anthropic
SDK sets its own capitalized `"User-Agent"`; the two are distinct dict keys, so httpx emits
both and joins them → `Anthropic/Python 0.87.0, claude-cli/2.1.165 (external, cli)`. A
polluted UA makes Anthropic bill the call as API / extra-usage instead of the subscription,
returning `400 "You're out of extra usage"`. (Verified empirically 2026-06-05; lines
962/1302 in the same file already use the capitalized form for the OAuth login path.)

**Change:** in that branch's `default_headers` dict, rename the key:

```diff
-            "user-agent": f"claude-cli/{_get_claude_code_version()} (external, cli)",
+            "User-Agent": f"claude-cli/{_get_claude_code_version()} (external, cli)",
```

(The in-place edit also carries a `# HERMES-GEO FORK` comment block.)

**Verify:** the outbound `/v1/messages` request must carry
`user-agent: claude-cli/<ver> (external, cli)` with **no** `Anthropic/Python` prefix.
See memory `hermes-model-provider`.
