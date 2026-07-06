# GeoBridge

HTTP daemon on the Mac exposing Geo tasks, cc-dispatch workers, and the hermes chat stream to the tailnet for the iPhone app. Dumb pipe over files — reads are verbatim bytes, mutations touch only `status`/`modifiedAt`, streams are line pass-through. Full spec: `CONTRACT.md`.

## Install

```sh
./install.sh
```

Idempotent: generates `~/.hermes/geobridge.token` (chmod 600) if missing, copies `ai.geo.bridge.plist` to `~/Library/LaunchAgents`, bootstraps and kickstarts `ai.geo.bridge`. `KeepAlive` means launchd retries until the tailnet bind succeeds.

Logs: access `~/Library/Logs/geobridge.log` (ts, source IP, method, path, status), stderr `~/Library/Logs/geobridge.err`.

For `/chat/stream` to work, hermes api_server must be enabled (see "Turning on hermes api_server" in `CONTRACT.md`).

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | no auth, `{"ok":true}` |
| GET | `/tasks` | verbatim splice of all task files |
| POST | `/tasks/{id}/complete` | sets `status` + `modifiedAt`, atomic write |
| POST | `/tasks/{id}/reopen` | same, back to `pending` |
| GET | `/dispatches` | newest-first, `{id, meta, status}` |
| GET | `/dispatches/{id}/stream` | SSE: replay + follow `log.jsonl`, `event: done` on exit |
| POST | `/chat/stream` | `{"session_id","message"}` → hermes session SSE, auto-creates session |

All except `/health` require `Authorization: Bearer <contents of ~/.hermes/geobridge.token>`.

## iPhone setup

- URL: `http://100.123.44.9:8643` (tailnet only)
- Token: contents of `~/.hermes/geobridge.token` on the Mac
- Reachability check: `GET /health` from the phone, then confirm the phone's tailnet IP shows up in `~/Library/Logs/geobridge.log`
