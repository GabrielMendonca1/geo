# GarimeCapture

Screenshot daemon for the Mac: watches the screenshot directory, OCRs each image locally with
Vision, hands the text to the **clipboard**, and keeps the image in a local archive for 30 days.
It has no network, and the OCR text is never written to disk — not to the vault, not to a spool,
not anywhere. The clipboard is the only sink.

## Two stages, deliberately decoupled

**Stage A — capture** (main thread, offline):
watch dir → wait for the file to stabilize → decode → clipboard phase 1 (image only) → Vision OCR →
write the image into `archive/<day>/`, atomically and `F_FULLFSYNC`ed → clipboard phase 2 (image +
OCR text + a `file://` URL pointing at the archived image) → **only then** delete the original
screenshot.

**Stage B — retention** (background thread, purely local):
every 6h, purge `archive/<day>/` folders older than 30 days. The gate is the *day folder name*, not
a file mtime — `cp`, rsync, Time Machine and iCloud all rewrite mtimes, the folder name is written
once and never touched again. **That name is the archiving day, not the capture day**: a screenshot
taken 45 days ago and only ingested today lands in `archive/<today>/` and gets its full 30 days.
Keying it on the capture date would make a backlog ingest born expired — archived, the original
unlinked, and reaped seconds later by the pass that runs at boot. Anything that is not a
`YYYY-MM-DD` directory sitting directly inside the archive — a foreign name, a symlink, a path that
resolves out of the archive — is logged and kept, never deleted. Inside a condemned day the reaper
is just as narrow: it deletes only regular files whose names match its own generated pattern, one by
one, and removes the day folder only if that leaves it empty. A file you dropped in there, a nested
folder, a symlink — all survive, and the day survives with them.

## Invariants

- **Nothing leaves the Mac.** The daemon links no networking library, spawns no subprocess, and
  contains no socket, `URLSession`, `ssh` or `scp` call path. This is structural, not a policy: the
  code that could reach a network was deleted, and the test suite fails if any of it comes back.
- **No markdown is ever generated or persisted.** The OCR text exists in memory and on the
  pasteboard, and nowhere else. Not even the log records it — only a character count.
- Nothing is ever written under `~/Vault/` or the retired `~/Library/Application Support/Geo/`.
  Both are hard-guarded; if `GARIME_CAPTURE_HOME` resolves inside either, the process exits 78.
- The original screenshot is deleted only after **both**: the archived image and its day directory
  are `F_FULLFSYNC`ed, *and* the clipboard payload is accepted by the pasteboard server. A panic at
  any point leaves the original in the watch dir, never a truncated capture as the only copy.
- **A failure never costs the original.** A failed archive write, a refused pasteboard, or any
  *transient* OCR error leaves the original exactly where it is and retries later. The archived image
  is kept across a retry — the name is a digest of the original name and bytes, so the retry rewrites
  the same file idempotently.
- **The retry budget is temporal and durable, not a bare counter.** Attempts back off
  `15s → 30 → 60 → 120` (capped at 300s), so a fault lasting longer than a poll interval still gets
  retried instead of burning all 5 attempts in 5 seconds. The ledger lives in
  `registry/failures.json`, so restarting the daemon does **not** refill the budget: a `launchctl
  kickstart` can no longer resurrect a doomed capture in a loop. Entries expire after 7 days, which
  is also the automatic second chance.
- **Only the first attempt primes the clipboard.** A retry observes `changeCount` instead of writing
  it, so a capture that fails repeatedly never overwrites what the user copied in the meantime. The
  clipboard is written once at the end, when there is actually OCR text to deliver.
- **A capture the daemon gave up on is published, not just logged.** After 5 attempts the filename is
  written to `status/stranded`, and the watchdog excludes those files from its unconsumed-screenshot
  probe. Without that, the watchdog kickstarts the daemon every 300s over a file a restart cannot
  fix. Fix the cause and delete the entry (or wait out the 7-day expiry) to retry.
- An OCR *refusal* is narrower than "Vision threw". Only `VNErrorCode.invalidImage` (an image ≤2px in
  any dimension, for one) is deterministic; no number of retries changes it, so such an image is
  archived with empty text and the original consumed, with the reason logged. Every other Vision
  error — `outOfMemory`, `internalError`, `operationFailed`, `ioError`, … — is transient and retried:
  treating them as refusals would consume the capture with empty text and report success.
- Clipboard phase 2 only overwrites the pasteboard if `changeCount` is unchanged since phase 1 —
  anything the user copied while OCR was running wins. In that case the OCR text is dropped and
  said so in the log: the user's deliberate copy counts as consuming the capture, and the original
  is still deleted. Retrying would re-prime the pasteboard with the image and clobber exactly the
  content the guard exists to protect.
- Images in the archive are deleted 30 days after the day they were **archived**. The retention
  clock starts when the daemon takes custody of the image, never at the moment the screenshot was
  taken.
- The reaper only ever deletes files it generated itself: a regular file matching
  `^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|jpg|jpeg|heic|heif)$`. `purged_files_total` counts exactly
  those; a day still holding anything else is kept and logged, and `purged_days_total` does not move.
- Images predating the daemon's first run are left in place; everything created after it is consumed
  no matter how long the daemon was down. The cutoff is the epoch in `registry/bootstrap`, not an
  age window, so a restart never abandons a backlog and a first run never eats an old Desktop.
- Archive names are generated at capture time: `<yyyyMMdd-HHmmss>-<10 hex>.<ext>`. The original
  filename never survives anywhere but the log line that records the ingest.
- **A spool left over from the retired upload stage is inert.** If `spool/` still holds files from a
  version that uploaded to the VM, every startup logs an `ERROR` naming the count. They are never
  sent (there is nothing to send with), never read, never moved and never deleted — cleaning them up
  is a manual decision, not something a daemon should do silently to files it can no longer explain.

## Layout on disk

```
~/Library/Application Support/Garime/GarimeCapture/
  archive/<YYYY-MM-DD>/   the captured images, local only, keyed on the archiving day,
                          purged 30 days after it
  status/capture.heartbeat
  status/retention.heartbeat
  status/retention.status archive_days/archive_files/archive_oldest_age_days/
                          purged_days_total/purged_files_total
  status/stranded         one filename per line the daemon gave up on; the watchdog
                          skips these instead of kickstarting forever
  registry/processed.json dedup keys, so a restart never reprocesses a screenshot
  registry/failures.json  retry ledger (attempts + next attempt), survives a restart
  registry/bootstrap      epoch of the first run; older images are never ingested
~/Library/Logs/garime/
  garimecapture.{out,err}
  garimecapture-watchdog.log
```

## Commands

```bash
garimecapture                     # daemon
garimecapture retention-once      # purge archived images past the retention window
garimecapture capture-once PATH…  # run the full pipeline on the given images (ops/test seam)
garimecapture clipboard-show      # print what is on the capture pasteboard
garimecapture ocr-classify D C    # how a Vision error (domain, code) is classified (test seam)
garimecapture paths               # print resolved paths
```

`capture-once` is the same code path the daemon runs per screenshot — OCR, archive, clipboard,
delete the original — not a shortcut around it.

## Environment

| Var | Default |
|---|---|
| `GARIME_CAPTURE_HOME` | `~/Library/Application Support/Garime/GarimeCapture` |
| `GARIME_WATCH_DIR` | unset — falls back to the `com.apple.screencapture` location, then Desktop |
| `GARIME_ARCHIVE_RETENTION_DAYS` | `30` days of local image archive |
| `GARIME_RETENTION_INTERVAL` | `21600` seconds between purge passes |
| `GARIME_RETENTION_MAX_AGE` | `86400` seconds before a stale retention heartbeat kicks (watchdog) |
| `GARIME_OCR_TIMEOUT` | `30` seconds before an OCR attempt is abandoned and retried |
| `GARIME_RETRY_BASE_DELAY` | `15` seconds before the 2nd attempt, doubling per attempt |
| `GARIME_RETRY_MAX_DELAY` | `300` seconds ceiling on the retry backoff |
| `GARIME_NOW` | unset — epoch override for the retention clock, test seam only |
| `GARIME_PASTEBOARD_NAME` | unset — targets a named pasteboard instead of the general one, test seam only |
| `GARIME_FAIL_CLIPBOARD` | unset — `all` / `final`, injects a pasteboard failure, test seam only |
| `GARIME_WATCHDOG_LAUNCHCTL` | `launchctl` — the binary the watchdog kickstarts through, test seam only |

## Install

```bash
./install.sh            # build + sign + install both LaunchAgents, idempotent
./tests/run.sh          # hermetic suite: real Vision, a named pasteboard, no network, no launchd mutation
```

`install.sh` builds, signs with a stable Apple Development identity (an ad-hoc signature would reset
TCC grants on every rebuild), installs `garimecapture` and the watchdog into `~/.local/bin`, and
bootstraps `ai.garime.capture` (`KeepAlive`) plus `ai.garime.capture-watchdog` (every 300s). Running
it twice is safe. `GARIME_INSTALL_SKIP_LAUNCHCTL=1` installs the files without touching launchd.

The watchdog checks the two heartbeats (capture 180s, retention 86400s, the latter only once the
daemon has written one) and logs an explicit error when the agent is not loaded at all, instead of
failing silently. A live heartbeat only proves the process is alive, so it also probes forward
progress directly: a screenshot sitting unconsumed in the watch dir for more than 3 minutes kicks
the agent. That probe is bounded by `registry/bootstrap` rather than a fixed 55-minute ceiling, so a
screenshot stuck for hours still raises the alarm. Files listed in `status/stranded` are excluded
from it: the daemon has already spent its budget on them and a kickstart cannot help, so alarming
would only produce a restart loop.

## Known gaps
- The clipboard's `fileURL` points at the archived image, so it stays valid for the whole retention
  window — but it does die when the archive is purged at 30 days. The image bytes and the OCR text
  in the same pasteboard item are unaffected.
- A clipboard manager running on the Mac bumps `changeCount` and can therefore suppress phase 2,
  costing the OCR text for that capture. The image is archived either way.
- The OCR text has exactly one copy, on the pasteboard, and the next copy overwrites it. That is the
  deliberate trade for never persisting it; if you want it kept, paste it somewhere.
- A clock jump *forward* is the only way to purge early: the cutoff is derived from the current
  time, and a parse failure or an unexpected shape always resolves to "keep". A jump backwards just
  delays the purge.
- A capture that exhausts its 5 attempts needs a human: the image stays in the watch dir and the
  daemon will not touch it again until the ledger entry expires after 7 days. That is deliberate —
  the alternative is the restart loop — but it means a fault fixed on day 1 is not retried until
  day 7 unless the entry is deleted from `registry/failures.json`.
- A *successful* retry still writes the clipboard, so a capture that failed minutes ago can land on
  the pasteboard well after the user stopped expecting it. Retries no longer prime, so this is one
  write with real OCR text rather than a stream of image-only clobbers.
