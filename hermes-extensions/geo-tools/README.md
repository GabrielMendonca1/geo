# geo-tools

Geo tools for Gabriel's macOS app, as a Hermes plugin. Native `geo_*` tool names
(no `mcp_` prefix), exposed to the gateway and standalone scripts.

## Model: the vault is truth, no socket

Geo's MCP server and localhost HTTP API are both retired. Every tool operates on
the filesystem directly — there is no port, no `api.json`, no Keychain token:

- **Reads** (`reads.py`) query the read-only `Index/blocks.sqlite` cache the
  Geo.app derives, falling back to a bounded glob+parse of the `.md` files when
  the app is mid-write or closed. Specific-id reads open the `.md` file directly.
- **Block writes** are native FS ops guarded by `guard.py` (agents may write only
  `Agente`/`Revisao`/`Compartilhado`, never `Voce/`). The Geo.app FileWatcher
  reconciles the derived index after any write.
- **Task CRUD + dedup** (`tasks_fs.py`) operate over `Tasks/*.json`.

## What's inside

| File | Role |
|---|---|
| `plugin.yaml` | Manifest. |
| `__init__.py` | Plugin entrypoint. Registers tools + the `pre_gateway_dispatch` hook. |
| `reads.py` | File-native read engine (RO sqlite index + file-scan fallback). |
| `tasks_fs.py` | Task CRUD/dedup over `Tasks/*.json`. |
| `_fs.py` | Vault path + frontmatter helpers. |
| `guard.py` | Layer guard — agents never write `Voce/`. |
| `matching.py` | Title `normalize()` + fuzzy `score()`/`rank()` for the semantic task tools. |
| `tools_read.py` / `tools_write.py` | Read / non-destructive write tool definitions. |
| `destructive.py` | `geo_delete_block` / `geo_delete_task` — Telegram confirm → native rm. |
| `client.py` | Just the `GeoError` exception the file-native modules raise. |
| `install.sh` | rsync into `~/.hermes/plugins/geo-tools/`. |

## Destructive flow (Telegram confirm)

`geo_delete_block` and `geo_delete_task` are two-phase: prepare a diff preview, DM
Gabriel via `send_message` → `telegram:…`, wait ~30 s polling for a `Y`, then
commit (native rm) or abort. Inbound replies are captured by a
`pre_gateway_dispatch` hook (see `destructive.py`).

## Task dedup (stop duplicate tasks)

- **`geo_upsert_task`** — fuzzy-matches the title against pending tasks; updates a
  match scoring `>= match_threshold` (default 0.82) instead of duplicating, else
  creates. `force_new=true` skips the check.
- **`geo_find_tasks`** — ranked search over pending (or all) tasks.
- **`geo_resolve_task`** — map a natural-language reference to ONE task id, or the
  top-3 candidates to disambiguate.

Normalization + scoring live in `matching.py` (stdlib only: accent-stripped,
lowercased, punctuation-dropped titles via `difflib.SequenceMatcher` ratio, token
Jaccard, and substring — taking the max).

## Install

```bash
bash install.sh
```

Idempotent. Re-run after edits; hermes picks up changes on next restart. Verify:

```bash
hermes plugins list | grep geo-tools
```
