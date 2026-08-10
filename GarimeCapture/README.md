# GarimeCapture

Screenshot daemon for the Mac: watches the screenshot directory, OCRs each image locally with
Vision, and ships the `image + .md` pair to the vault **on the VM garime**. It never writes into
`~/Vault/` — the Mac is a sensor, the VM holds the vault.

## Two stages, deliberately decoupled

**Stage A — capture** (main thread, offline, no network):
watch dir → wait for the file to stabilize → decode → clipboard phase 1 (image only) → Vision OCR →
clipboard phase 2 → write the `image + .md` pair atomically into the local spool → **only then**
delete the original screenshot.

**Stage B — upload** (background thread, never blocks capture):
every 45s, drain the spool to `garime:/mnt/garime/Vault/Captures/<day>/`. On failure the spool is
left untouched and the pass is retried with exponential backoff (5s → 300s, jittered, never gives
up). Because the pair is already complete on disk, **a retry re-copies files but never re-runs OCR**.

Keeping the upload off the capture thread is the point: a slow network must not stall OCR, stop the
capture heartbeat, and get the whole process killed by the watchdog mid-transfer.

Clipboard phase 2 only overwrites the pasteboard if `changeCount` is unchanged since phase 1 —
anything the user copied while OCR was running wins.

## Invariants

- Nothing is ever written under `~/Vault/` or the retired `~/Library/Application Support/Geo/`.
  Both are hard-guarded; if `GARIME_CAPTURE_HOME` resolves inside either, the process exits 78.
- The original screenshot is deleted only after the pair is durably spooled: both files and their
  day directory are `F_FULLFSYNC`ed before the delete, so a panic cannot leave a truncated capture
  as the only surviving copy.
- A spooled file is pruned only after the remote publish is confirmed.
- Only files matching `^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|jpg|jpeg|heic|heif|md)$` are uploaded.
  Anything else in the spool — notably the `.sb-*` temporaries an atomic write creates — is skipped
  and logged, never published and never unlinked out from under its writer.
- Images predating the daemon's first run are left in place; everything created after it is consumed
  no matter how long the daemon was down. The cutoff is the epoch in `registry/bootstrap`, not an
  age window, so a restart never abandons a backlog and a first run never eats an old Desktop.
- Remote names are generated once, at spool time: `<yyyyMMdd-HHmmss>-<10 hex>.<ext>`. The original
  filename never reaches an argv — it survives only as an escaped `source:` field in the markdown.
- `ssh`/`scp` are invoked with an argument array, never through a shell, always with
  `BatchMode=yes` (no interactive prompt can hang a headless agent) and `ConnectTimeout`. Every
  invocation is additionally bounded by a wall-clock timeout and killed if it stalls mid-transfer.
- Uploads stage into `<day>/.incoming/` and are published with a remote `mv`, so a partial transfer
  is never visible under `<day>/`.

## Layout on disk

```
~/Library/Application Support/Garime/GarimeCapture/
  spool/<YYYY-MM-DD>/     pending image + .md pairs
  status/capture.heartbeat
  status/upload.heartbeat
  status/upload.status    last_pass/last_success/failures/spool_files/spool_oldest_age
  registry/processed.json dedup keys, so a restart never reprocesses a screenshot
  registry/bootstrap      epoch of the first run; older images are never ingested
~/Library/Logs/garime/
  garimecapture.{out,err}
  garimecapture-watchdog.log
```

## Commands

```bash
garimecapture                 # daemon
garimecapture upload-once     # drain the spool once; exit 0 drained, 1 failed
garimecapture spool-add PATH… # ingest files into the spool without OCR (ops/test seam)
garimecapture paths           # print resolved paths and the remote target
```

## Environment

| Var | Default |
|---|---|
| `GARIME_CAPTURE_HOME` | `~/Library/Application Support/Garime/GarimeCapture` |
| `GARIME_WATCH_DIR` | unset — falls back to the `com.apple.screencapture` location, then Desktop |
| `GARIME_REMOTE_HOST` / `GARIME_REMOTE_ROOT` | `garime` / `/mnt/garime/Vault/Captures` |
| `GARIME_SSH_BIN` / `GARIME_SCP_BIN` | `/usr/bin/ssh` / `/usr/bin/scp` |
| `GARIME_SSH_KEY` | `~/.ssh/garime` (passed as `-i` with `IdentitiesOnly=yes` when readable) |
| `GARIME_CONNECT_TIMEOUT` / `GARIME_SSH_TIMEOUT` | `10` / `120` seconds |
| `GARIME_UPLOAD_INTERVAL` / `GARIME_UPLOAD_BACKOFF_MAX` | `45` / `300` seconds |
| `GARIME_UPLOAD_BATCH` | `20` files per scp call |
| `GARIME_UPLOAD_STALL_MAX` / `GARIME_UPLOAD_FAIL_ALERT` | `3600` seconds / `10` failures (watchdog) |

Host and remote root are validated against a whitelist before any process is spawned; an unsafe
value refuses the upload instead of executing it.

## Install

```bash
./install.sh            # build + sign + install both LaunchAgents, idempotent
./tests/run.sh          # hermetic suite: fake ssh/scp, real Vision, no launchd mutation
GARIME_TEST_LIVE=1 ./tests/run.sh   # adds T15: real ssh/scp against a scratch dir on the host
```

`install.sh` builds, signs with a stable Apple Development identity (an ad-hoc signature would reset
TCC grants on every rebuild), installs `garimecapture` and the watchdog into `~/.local/bin`, and
bootstraps `ai.garime.capture` (`KeepAlive`) plus `ai.garime.capture-watchdog` (every 300s). Running
it twice is safe. `GARIME_INSTALL_SKIP_LAUNCHCTL=1` installs the files without touching launchd.

The watchdog checks both heartbeats (capture 180s, upload 1800s — a slow network must not kill OCR)
and logs an explicit error when the agent is not loaded at all, instead of failing silently.

A live heartbeat only proves the process is alive, so the watchdog also probes forward progress via
`status/upload.status`: if the spool is non-empty and there has been no successful upload for
`GARIME_UPLOAD_STALL_MAX` (3600s), or the consecutive-failure count reaches `GARIME_UPLOAD_FAIL_ALERT`
(10), it logs `ERROR` and exits 2. It does not kickstart in that case — restarting does not fix a
down remote. `last_success` is persisted, so a kickstart cannot reset the alarm clock. The
unconsumed-screenshot probe is bounded by `registry/bootstrap` rather than a fixed 55-minute
ceiling, so a screenshot stuck for hours still raises the alarm.

## Known gaps
- The clipboard's `fileURL` points at the spooled file, which disappears once uploaded. The image
  bytes and OCR text in the same pasteboard item are unaffected.
