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

## Training v1 static sources

`training/` is the canonical source for the real static catalog, blocks, and conservative safety governance. It deliberately contains no weekly plan, `protocol.json`, or `state.json`. The catalog can retain blocked exercises for future discovery, while `publishable: true` blocks exclude all currently locked, conditional, or pending exercises. These files are source artifacts only: this repository does not deploy or seed them automatically.

`fixtures/training/` remains a separate generic demonstration catalog, one reusable block, and a frozen seven-day ISO-week snapshot for contract tests. It contains no individualized guidance and no `safety.json`.

After comparing the deployed `/opt/garime/geobridge.py` with this checkout and deploying through the normal VM procedure, an operator can seed the read-only library and submit the write-once example plan explicitly:

```sh
sudo -u biel install -m 600 fixtures/training/catalog.json /mnt/garime/state/health/catalog.json
sudo -u biel install -m 600 fixtures/training/blocks.json /mnt/garime/state/health/blocks.json
curl -fsS -X POST \
  -H "Authorization: Bearer $(cat /etc/garime/bridge.token)" \
  -H 'Content-Type: application/json' \
  --data-binary @fixtures/training/plan-2026-W35.r1.json \
  http://127.0.0.1:8643/vitals/plan
```

Run the file installs as the bridge runtime user (`biel`) so mode `600` remains readable by GeoBridge. The sample is fixed to the checkout's current week, `2026-W35`; a different week requires updating `week`, `id`, and all seven dates together. Rollback removes only `catalog.json`, `blocks.json`, and matching `plan-*.json`; legacy `protocol.json`, `state.json`, and `log-*.json` must not be touched.
