# GarimeCapture

Screenshot daemon for the Mac: watches the screenshot directory, OCRs each image locally with
Vision, ships **only the `.md`** to the vault **on the VM garime**, and keeps the image in a local
archive for 30 days. It never writes into `~/Vault/` — the Mac is a sensor, the VM holds the vault.

## Three stages, deliberately decoupled

**Stage A — capture** (main thread, offline, no network):
watch dir → wait for the file to stabilize → decode → clipboard phase 1 (image only) → Vision OCR →
clipboard phase 2 → write the image into `archive/<day>/` and the `.md` into `spool/<day>/`, each
atomically and `F_FULLFSYNC`ed → **only then** delete the original screenshot.

**Stage B — upload** (background thread, never blocks capture):
every 45s, drain the spool to `garime:/mnt/garime/Vault/Captures/<day>/`. Only `.md` files are ever
uploaded — the image is already out of the spool before the uploader can see it, and any image that
still turns up in the spool (a pre-upgrade spool, say) is moved into the archive instead of being
sent. On failure the spool is left untouched and the pass is retried with exponential backoff
(5s → 300s, jittered, never gives up). Because the `.md` is already complete on disk, **a retry
re-copies files but never re-runs OCR**.

**Stage C — retention** (background thread, purely local, never waits on the uploader):
every 6h, purge `archive/<day>/` folders older than 30 days. The gate is the *day folder name*, not
a file mtime — `cp`, rsync, Time Machine and iCloud all rewrite mtimes, the folder name is written
once and never touched again. **That name is the archiving day, not the capture day**: a screenshot
taken 45 days ago and only ingested today lands in `archive/<today>/` and gets its full 30 days.
Keying it on the capture date would make a backlog ingest born expired — archived, the original
unlinked, and reaped seconds later by the pass that runs at boot. The `.md` therefore keeps *two*
dates: `captured:` / its `spool/<day>/` folder are the semantic capture day (that is what the VM
`Captures/<day>/` destination follows), and `archived:` records the archive day the image actually
sits under, which may differ. Anything that is not a `YYYY-MM-DD` directory sitting directly inside
the archive — a foreign name, a symlink, a path that resolves out of the archive — is logged and
kept, never deleted. Inside a condemned day the reaper is just as narrow: it deletes only regular
files whose names match its own generated pattern, one by one, and removes the day folder only if
that leaves it empty. A file you dropped in there, a nested folder, a symlink — all survive, and the
day survives with them.

Keeping the upload off the capture thread is the point: a slow network must not stall OCR, stop the
capture heartbeat, and get the whole process killed by the watchdog mid-transfer.

Clipboard phase 2 only overwrites the pasteboard if `changeCount` is unchanged since phase 1 —
anything the user copied while OCR was running wins.

## Invariants

- Nothing is ever written under `~/Vault/` or the retired `~/Library/Application Support/Geo/`.
  Both are hard-guarded; if `GARIME_CAPTURE_HOME` resolves inside either, the process exits 78.
- **No image ever leaves the Mac.** Only `.md` files are handed to `scp`; the uploader filters by
  extension before building the argv, so an image cannot reach the VM even if one appears in the
  spool. Nothing in this daemon ever issues a remote delete, so images already sitting on the VM
  from before this rule are left exactly as they are.
- The original screenshot is deleted only after **both** durable writes land: the archived image and
  its day directory are `F_FULLFSYNC`ed, then the spooled `.md` and its day directory. A panic at
  any point leaves the original in the watch dir, never a truncated capture as the only copy.
- If the `.md` write fails after the image is archived, the archived image is **kept** — the name is
  a digest of the original name and bytes, so the retry rewrites the same file idempotently.
  Deleting from the archive is the retention pass's exclusive right; nothing else unlinks an image.
- Images in the archive are deleted 30 days after the day they were **archived**, whether or not
  their `.md` ever reached the VM. The retention clock starts when the daemon takes custody of the
  image, never at the moment the screenshot was taken.
- The reaper only ever deletes files it generated itself: a regular file matching
  `^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|jpg|jpeg|heic|heif|md)$`. `purged_files_total` counts
  exactly those; a day still holding anything else is kept and logged, and `purged_days_total` does
  not move.
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
  spool/<YYYY-MM-DD>/     .md files pending upload — never images
  archive/<YYYY-MM-DD>/   the captured images, local only, keyed on the archiving day,
                          purged 30 days after it
  status/capture.heartbeat
  status/upload.heartbeat
  status/retention.heartbeat
  status/upload.status    last_pass/last_success/failures/spool_files/spool_oldest_age
  status/retention.status archive_days/archive_files/archive_oldest_age_days/pending_md/
                          pending_images/purged_days_total/purged_files_total
  registry/processed.json dedup keys, so a restart never reprocesses a screenshot
  registry/bootstrap      epoch of the first run; older images are never ingested
~/Library/Logs/garime/
  garimecapture.{out,err}
  garimecapture-watchdog.log
```

## Commands

```bash
garimecapture                  # daemon
garimecapture upload-once      # drain the spool once; exit 0 drained, 1 failed
garimecapture retention-once   # purge archived images past the retention window
garimecapture spool-add PATH…  # ingest files into the spool without OCR (ops/test seam)
garimecapture paths            # print resolved paths and the remote target
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
| `GARIME_ARCHIVE_RETENTION_DAYS` | `30` days of local image archive |
| `GARIME_RETENTION_INTERVAL` | `21600` seconds between purge passes |
| `GARIME_RETENTION_MAX_AGE` | `86400` seconds before a stale retention heartbeat kicks (watchdog) |
| `GARIME_NOW` | unset — epoch override for the retention clock, test seam only |

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

The watchdog checks all three heartbeats (capture 180s, upload 1800s — a slow network must not kill
OCR — and retention 86400s, only once the daemon has written one) and logs an explicit error when
the agent is not loaded at all, instead of failing silently.

A live heartbeat only proves the process is alive, so the watchdog also probes forward progress via
`status/upload.status`: if the spool is non-empty and there has been no successful upload for
`GARIME_UPLOAD_STALL_MAX` (3600s), or the consecutive-failure count reaches `GARIME_UPLOAD_FAIL_ALERT`
(10), it logs `ERROR` and exits 2. It does not kickstart in that case — restarting does not fix a
down remote. `last_success` is persisted, so a kickstart cannot reset the alarm clock. The
unconsumed-screenshot probe is bounded by `registry/bootstrap` rather than a fixed 55-minute
ceiling, so a screenshot stuck for hours still raises the alarm. Those alarms count *pending
markdown*, which is what `spool_files` now measures; the archived images are reported separately in
`retention.status`, and a non-zero `pending_images` there is its own `ERROR` + exit 2.
`pending_images` counts every regular file in the spool that is not an uploadable `.md`, whatever
its name — the uploader's whitelist keeps foreign files out of the argv, so a file it refuses to
touch would otherwise sit there forever behind a green watchdog.

## Known gaps
- The clipboard's `fileURL` points at the archived image, so it stays valid for the whole retention
  window instead of the ~45s until the next upload — but it does die when the archive is purged.
  The image bytes and OCR text in the same pasteboard item are unaffected.
- **Retention does not wait for the upload.** If the VM is unreachable for more than 30 days, the
  image is purged while its `.md` is still queued. The OCR text is never lost (the uploader backs
  off but never gives up); the image is. This is the one data-loss window in the design.
- A clock jump *forward* is the only way to purge early: the cutoff is derived from the current
  time, and a parse failure or an unexpected shape always resolves to "keep". A jump backwards just
  delays the purge.
- A file the daemon cannot move out of the spool (a cross-volume `archive/`, a permission fault, a
  name that fails the whitelist) stays in the spool forever: never uploaded, never deleted, logged on
  every pass and surfaced as `pending_images` in `retention.status`, which the watchdog alarms on.
