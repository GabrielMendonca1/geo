#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/garimecapture"
TMP="/tmp/garimecapture-test-$$"
TODAY="$(date +%Y-%m-%d)"
FAILURES=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok: $*"; }
section() { echo; echo "== $* =="; }

section "build"
"$ROOT/build.sh" >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }
[ -x "$BIN" ] || { echo "missing binary $BIN" >&2; exit 1; }
ok "compiled $BIN"

mkdir -p "$TMP/base" "$TMP/shots" "$TMP/fake-bin"
cp "$ROOT"/tests/fake-bin/* "$TMP/fake-bin/"
chmod 755 "$TMP/fake-bin"/*

unset GARIME_ARCHIVE_DIR GARIME_ARCHIVE_LAYOUT
export GARIME_CAPTURE_HOME="$TMP/base"
export GARIME_PASTEBOARD_NAME="ai.garime.capture.test.$$"
export GARIME_NETWORK_TRIPWIRE="$TMP/network.log"
export PATH="$TMP/fake-bin:$PATH"
: > "$GARIME_NETWORK_TRIPWIRE"

export GARIME_WATCHDOG_LAUNCHCTL="$TMP/launchctl-recorder"
export GARIME_LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$GARIME_LAUNCHCTL_LOG"
cat > "$GARIME_WATCHDOG_LAUNCHCTL" <<'RECORDER'
#!/bin/sh
echo "$*" >> "$GARIME_LAUNCHCTL_LOG"
[ "$1" = "print" ] && exec /bin/launchctl "$@"
exit 0
RECORDER
chmod 755 "$GARIME_WATCHDOG_LAUNCHCTL"

ARCHIVE="$TMP/base/archive"
OCR_FIXTURE="$ROOT/tests/fixtures/ocr.png"
OCR_TEXT="GARIME OCR"
BLANK_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
ART_RE='^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|jpg|jpeg|heic|heif)$'

vault_count() {
  [ -d "$HOME/Gabriel" ] || { echo 0; return; }
  find "$HOME/Gabriel" -type f 2>/dev/null | wc -l | tr -d ' '
}
VAULT_BEFORE="$(vault_count)"

make_shot() { printf '%s' "$BLANK_B64" | base64 --decode > "$TMP/shots/$1"; }
make_text_shot() { cp "$OCR_FIXTURE" "$1"; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

section "T1 the real daemon loop: watch -> OCR -> clipboard -> archive"
mkdir -p "$TMP/watch"
GARIME_WATCH_DIR="$TMP/watch" "$BIN" >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 60); do
  [ -f "$TMP/base/registry/bootstrap" ] && break
  sleep 1
done
[ -f "$TMP/base/registry/bootstrap" ] && ok "daemon reached its first scan" || fail "daemon never scanned"
make_text_shot "$TMP/watch/ocr-case.png"
ORIGINAL_SUM="$(shasum "$TMP/watch/ocr-case.png" | awk '{print $1}')"
for _ in $(seq 1 60); do
  [ "$(find "$ARCHIVE/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 1
done
sleep 1
kill "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null

kept="$(find "$ARCHIVE/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$kept" = "1" ] && ok "the image is archived locally" || fail "expected 1 archived image, got $kept"
ARCHIVED="$(find "$ARCHIVE/$TODAY" -type f -name '*.png' | head -1)"
[ "$(shasum "$ARCHIVED" | awk '{print $1}')" = "$ORIGINAL_SUM" ] \
  && ok "the archived bytes are the original bytes" || fail "the archived image was rewritten"
[ ! -e "$TMP/watch/ocr-case.png" ] && ok "original consumed by the daemon" || fail "original left in the watch dir"
grep -q 'Vision model warm' "$TMP/daemon.log" && ok "Vision OCR ran in-process" || fail "no Vision warm-up"
[ -f "$TMP/base/status/capture.heartbeat" ] && ok "capture heartbeat written" || fail "no capture heartbeat"
[ -f "$TMP/base/status/retention.heartbeat" ] && ok "retention heartbeat written" || fail "no retention heartbeat"
[ ! -e "$TMP/base/status/upload.heartbeat" ] && ok "no upload heartbeat exists any more" || fail "an upload heartbeat was written"
[ ! -e "$TMP/base/status/upload.status" ] && ok "no upload status file" || fail "an upload.status was written"
[ ! -d "$TMP/base/spool" ] && ok "no spool directory is created" || fail "the daemon recreated a spool dir"

section "T2 the clipboard is the only sink for the OCR text"
CLIP="$TMP/clipboard.txt"
"$BIN" clipboard-show > "$CLIP" 2>&1
grep -q "^string=.*$OCR_TEXT" "$CLIP" && ok "the OCR text is on the pasteboard" || fail "no OCR text on the pasteboard: $(cat "$CLIP")"
grep -q "^fileURL=file://.*$(basename "$ARCHIVED")" "$CLIP" \
  && ok "the archived image fileURL is on the pasteboard" || fail "no archive fileURL on the pasteboard"
grep -q '^type=public.png' "$CLIP" && ok "the image itself is on the pasteboard" || fail "no image on the pasteboard"
imagebytes="$(sed -n 's/^imageBytes=//p' "$CLIP")"
[ "${imagebytes:-0}" -gt 0 ] && ok "the pasteboard image carries $imagebytes bytes" || fail "the pasteboard image is empty"

section "T3 zero markdown, zero OCR text anywhere on disk"
md="$(find "$TMP/base" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$md" = "0" ] && ok "not a single .md exists under the capture home" || fail "$md markdown file(s) found"
if grep -rlI "$OCR_TEXT" "$TMP/base" >/dev/null 2>&1; then
  fail "the OCR text was persisted: $(grep -rlI "$OCR_TEXT" "$TMP/base" | tr '\n' ' ')"
else
  ok "the OCR text appears in no file under the capture home"
fi
if grep -q "$OCR_TEXT" "$TMP/daemon.log"; then
  fail "the OCR text leaked into the daemon log"
else
  ok "the daemon log reports a char count, never the text"
fi
bad=0
while IFS= read -r f; do
  name="$(basename "$f")"
  echo "$name" | grep -Eq "$ART_RE" || { fail "unexpected file in the archive: $name"; bad=1; }
done < <(find "$ARCHIVE" -type f)
[ "$bad" = "0" ] && ok "every archived file matches the image whitelist"
grep -q 'frontmatter\|yamlEscape\|\.md' "$ROOT/Sources"/*.swift && fail "markdown machinery survives in the sources" \
  || ok "no markdown machinery left in the sources"

section "T4 zero network, structurally"
[ ! -s "$GARIME_NETWORK_TRIPWIRE" ] && ok "no ssh/scp/curl/nc/rsync/sftp was ever invoked" \
  || fail "a network tool was invoked: $(cat "$GARIME_NETWORK_TRIPWIRE")"
if grep -nE 'URLSession|NWConnection|CFSocket|socket\(|Process\(|\bssh\b|\bscp\b|curl|https?://' "$ROOT/Sources"/*.swift; then
  fail "a network or subprocess primitive survives in the sources"
else
  ok "no network or subprocess primitive in the sources"
fi
if otool -L "$BIN" | grep -qE 'libcurl|CFNetwork|/Network\.framework/'; then
  fail "the binary links a networking library"
else
  ok "the binary links no networking library"
fi
[ ! -e "$ROOT/Sources/Uploader.swift" ] && ok "Uploader.swift is gone" || fail "Uploader.swift still exists"
for var in GARIME_REMOTE_HOST GARIME_REMOTE_ROOT GARIME_SSH_BIN GARIME_SCP_BIN GARIME_SSH_KEY; do
  grep -q "$var" "$ROOT/Sources"/*.swift "$ROOT/garimecapture-watchdog.sh" "$ROOT/install.sh" \
    && fail "$var is still referenced" || ok "$var is gone"
done

section "T5 hostile filenames are sanitized before they reach the archive"
rm -rf "$TMP/base/archive"
PWNED="$TMP/pwned-marker"
cd "$TMP"
make_shot '`touch pwned-marker`.png'
make_shot '$(touch pwned-marker).png'
make_shot '-oProxyCommand=evil.png'
make_shot '..--..--etc--passwd.png'
make_shot 'name with spaces & $HOME.png'
find "$TMP/shots" -type f -print0 | xargs -0 "$BIN" capture-once >"$TMP/hostile.log" 2>&1
[ ! -e "$PWNED" ] && ok "no shell evaluation of filenames" || fail "hostile filename was evaluated by a shell"
grep -q 'OCR refused' "$TMP/hostile.log" \
  && ok "Vision refuses a 1x1 image and says so" || fail "expected a refusal for the 1x1 fixtures"
[ "$(count_files "$TMP/shots")" = "0" ] && ok "originals removed after a durable archive" \
  || fail "originals left behind: $(count_files "$TMP/shots")"
archived="$(find "$ARCHIVE/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$archived" = "5" ] && ok "5 images archived (an un-OCR-able image is still archived, never stranded)" \
  || fail "expected 5 archived images, got $archived"
bad=0
while IFS= read -r f; do
  echo "$(basename "$f")" | grep -Eq "$ART_RE" || { fail "unsafe archive name: $(basename "$f")"; bad=1; }
done < <(find "$ARCHIVE/$TODAY" -type f)
[ "$bad" = "0" ] && ok "every generated name matches the safe whitelist"

section "T6 a failed archive write never costs the original"
rm -rf "$TMP/base9"
mkdir -p "$TMP/base9/archive"
chmod 500 "$TMP/base9/archive"
make_text_shot "$TMP/shots/ordering-case.png"
env GARIME_CAPTURE_HOME="$TMP/base9" "$BIN" capture-once "$TMP/shots/ordering-case.png" >"$TMP/order.log" 2>&1
STATUS=$?
chmod 700 "$TMP/base9/archive"
[ "$STATUS" -ne 0 ] && ok "capture-once reports the failure" || fail "capture-once masked an archive failure"
[ -f "$TMP/shots/ordering-case.png" ] && ok "original kept when the archive write fails" \
  || fail "original deleted without a durable archive copy"
[ "$(count_files "$TMP/base9/archive")" = "0" ] && ok "nothing half-written in the archive" || fail "a partial archive file survived"
[ "$(find "$TMP/base9" -name '*.md' | wc -l | tr -d ' ')" = "0" ] && ok "no markdown was produced on the failure path" \
  || fail "a markdown file appeared"
env GARIME_CAPTURE_HOME="$TMP/base9" "$BIN" capture-once "$TMP/shots/ordering-case.png" >/dev/null 2>&1 \
  && ok "the retry succeeds once the archive is writable" || fail "retry failed"
[ ! -e "$TMP/shots/ordering-case.png" ] && ok "original consumed on the successful retry" || fail "original kept after success"

section "T7 a clipboard failure never costs the original"
rm -rf "$TMP/base10"
make_text_shot "$TMP/shots/clip-case.png"
env GARIME_CAPTURE_HOME="$TMP/base10" GARIME_FAIL_CLIPBOARD=all \
  "$BIN" capture-once "$TMP/shots/clip-case.png" >"$TMP/clipfail.log" 2>&1
STATUS=$?
[ "$STATUS" -ne 0 ] && ok "capture-once reports the clipboard failure" || fail "clipboard failure reported green"
[ -f "$TMP/shots/clip-case.png" ] && ok "original kept when the clipboard is unavailable" || fail "original deleted with no clipboard"
[ "$(count_files "$TMP/base10/archive")" = "0" ] && ok "nothing archived when the clipboard dies before OCR" \
  || fail "archived despite a dead clipboard"

env GARIME_CAPTURE_HOME="$TMP/base10" GARIME_FAIL_CLIPBOARD=final \
  "$BIN" capture-once "$TMP/shots/clip-case.png" >"$TMP/clipfail2.log" 2>&1
STATUS=$?
[ "$STATUS" -ne 0 ] && ok "a failed final delivery is reported" || fail "final clipboard failure reported green"
[ -f "$TMP/shots/clip-case.png" ] && ok "original kept when the OCR text cannot be delivered" \
  || fail "original deleted before the OCR text was delivered"
[ "$(count_files "$TMP/base10/archive")" = "1" ] && ok "the archived image is kept for the retry" \
  || fail "expected the archived image to survive for the retry"
env GARIME_CAPTURE_HOME="$TMP/base10" "$BIN" capture-once "$TMP/shots/clip-case.png" >/dev/null 2>&1 \
  && ok "the retry delivers and consumes the original" || fail "clean retry failed"
[ "$(count_files "$TMP/base10/archive")" = "1" ] \
  && ok "the retry rewrote the same digest-named file, no duplicate" || fail "the retry duplicated the archived image"
[ ! -e "$TMP/shots/clip-case.png" ] && ok "original consumed only after a delivered clipboard" || fail "original survived a success"

section "T8 an OCR failure never costs the original"
rm -rf "$TMP/base16"
make_text_shot "$TMP/shots/ocrfail-case.png"
env GARIME_CAPTURE_HOME="$TMP/base16" GARIME_OCR_TIMEOUT=0.001 \
  "$BIN" capture-once "$TMP/shots/ocrfail-case.png" >"$TMP/ocrfail.log" 2>&1
STATUS=$?
[ "$STATUS" -ne 0 ] && ok "capture-once reports the OCR failure" || fail "OCR failure reported green"
grep -q 'OCR timed out' "$TMP/ocrfail.log" && ok "the timeout is logged" || fail "no timeout log line"
[ -f "$TMP/shots/ocrfail-case.png" ] && ok "original kept when OCR fails" || fail "original deleted after a failed OCR"
[ "$(count_files "$TMP/base16/archive")" = "0" ] && ok "nothing archived on a failed OCR" || fail "archived despite a failed OCR"
env GARIME_CAPTURE_HOME="$TMP/base16" "$BIN" capture-once "$TMP/shots/ocrfail-case.png" >/dev/null 2>&1 \
  && ok "the retry succeeds once OCR has time" || fail "OCR retry failed"

section "T9 the ~/Gabriel guard refuses to run"
GARIME_CAPTURE_HOME="$HOME/Gabriel/garimecapture-guard-$$" "$BIN" paths >"$TMP/guard.log" 2>&1
STATUS=$?
[ "$STATUS" -eq 78 ] && ok "exits 78 when capture home resolves into ~/Gabriel" || fail "guard did not trigger (exit $STATUS)"
[ ! -d "$HOME/Gabriel/garimecapture-guard-$$" ] && ok "nothing created under ~/Gabriel" || fail "guard created a dir in ~/Gabriel"
grep -q 'forbidden vault root' "$TMP/guard.log" && ok "guard logged the refusal" || fail "guard did not log"
VAULT_AFTER="$(vault_count)"
[ "$VAULT_BEFORE" = "$VAULT_AFTER" ] && ok "~/Gabriel untouched ($VAULT_AFTER files)" \
  || fail "~/Gabriel changed: $VAULT_BEFORE -> $VAULT_AFTER"

section "T10 the archive is purged at 30 days, not before"
rm -rf "$TMP/base7" "$TMP/outside7"
LEG="20200102-030405-0123456789"
NOON="$(date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 12:00:00" +%s)"
D29="$(date -v-29d +%Y-%m-%d)"
D30="$(date -v-30d +%Y-%m-%d)"
D31="$(date -v-31d +%Y-%m-%d)"
D45="$(date -v-45d +%Y-%m-%d)"
D60="$(date -v-60d +%Y-%m-%d)"
mkdir -p "$TMP/outside7"
printf 'precious' > "$TMP/outside7/keepme.png"
for d in "$D29" "$D30" "$D31" "$D45"; do
  mkdir -p "$TMP/base7/archive/$d"
  cp "$OCR_FIXTURE" "$TMP/base7/archive/$d/$LEG.png"
done
mkdir -p "$TMP/base7/archive/not-a-day"
printf 'foreign' > "$TMP/base7/archive/not-a-day/marker"
ln -s "$TMP/outside7" "$TMP/base7/archive/$D60"

env GARIME_CAPTURE_HOME="$TMP/base7" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention1.log" 2>&1 \
  && ok "retention-once exited 0" || fail "retention-once failed: $(cat "$TMP/retention1.log")"
[ -d "$TMP/base7/archive/$D29" ] && ok "29 days old kept" || fail "29-day-old archive purged early"
[ -d "$TMP/base7/archive/$D30" ] && ok "30 days old kept (the cutoff day survives)" || fail "30-day-old archive purged early"
[ ! -e "$TMP/base7/archive/$D31" ] && ok "31 days old purged" || fail "31-day-old archive survived"
[ ! -e "$TMP/base7/archive/$D45" ] && ok "45 days old purged" || fail "45-day-old archive survived"
[ -f "$TMP/base7/archive/not-a-day/marker" ] && ok "malformed folder left alone" || fail "malformed folder deleted"
grep -q 'skipping foreign entry' "$TMP/retention1.log" && ok "foreign entry logged" || fail "foreign entry skipped silently"
[ -L "$TMP/base7/archive/$D60" ] && ok "symlinked day not followed" || fail "symlinked day removed"
[ -f "$TMP/outside7/keepme.png" ] && ok "nothing outside the archive was touched" \
  || fail "purge escaped the archive through a symlink"

RET_FILE="$TMP/base7/status/retention.status"
[ -f "$RET_FILE" ] && ok "retention.status written" || fail "no retention.status"
grep -q '^purged_days_total=2$' "$RET_FILE" && ok "purged day counter exported (2)" \
  || fail "purged days wrong: $(grep '^purged_days_total=' "$RET_FILE")"
grep -q '^purged_files_total=2$' "$RET_FILE" && ok "purged file counter exported (2)" \
  || fail "purged files wrong: $(grep '^purged_files_total=' "$RET_FILE")"
grep -qE '^pending_(md|images)=' "$RET_FILE" && fail "the retired spool counters are still exported" \
  || ok "no spool counters in retention.status"

env GARIME_CAPTURE_HOME="$TMP/base7" GARIME_NOW="$NOON" "$BIN" retention-once >/dev/null 2>&1
grep -q '^purged_days_total=2$' "$RET_FILE" && ok "a second pass purges nothing new" || fail "counter moved on an idempotent pass"
[ -d "$TMP/base7/archive/$D30" ] && ok "restart-safe: the 30-day folder still stands" || fail "second pass ate the cutoff day"

section "T11 a condemned day loses only the artifacts this daemon generated"
rm -rf "$TMP/base14" "$TMP/outside14"
LEG2="20200102-030406-0123456789"
mkdir -p "$TMP/base14/archive/$D45/nested" "$TMP/outside14"
printf 'precious' > "$TMP/outside14/keepme.png"
cp "$OCR_FIXTURE" "$TMP/base14/archive/$D45/$LEG.png"
printf 'user notes' > "$TMP/base14/archive/$D45/NOTES.txt"
printf 'nested user file' > "$TMP/base14/archive/$D45/nested/inner.txt"
ln -s "$TMP/outside14/keepme.png" "$TMP/base14/archive/$D45/$LEG2.png"
env GARIME_CAPTURE_HOME="$TMP/base14" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention4.log" 2>&1 \
  && ok "retention-once exited 0" || fail "retention-once failed: $(cat "$TMP/retention4.log")"
[ ! -e "$TMP/base14/archive/$D45/$LEG.png" ] && ok "the generated artifact is purged" || fail "the expired artifact survived"
[ -f "$TMP/base14/archive/$D45/NOTES.txt" ] && ok "a foreign file inside the day survives" || fail "NOTES.txt was deleted"
[ -f "$TMP/base14/archive/$D45/nested/inner.txt" ] && ok "a nested subdirectory survives" || fail "the nested user file was deleted"
[ -L "$TMP/base14/archive/$D45/$LEG2.png" ] && ok "a symlink entry is kept, not followed" || fail "the symlink entry was deleted"
[ -f "$TMP/outside14/keepme.png" ] && ok "nothing outside the archive was touched" || fail "the purge escaped through a symlink"
[ -d "$TMP/base14/archive/$D45" ] && ok "the day dir survives while it still holds foreign content" \
  || fail "the day dir was removed with user files inside"
RET14="$TMP/base14/status/retention.status"
grep -q '^purged_files_total=1$' "$RET14" && ok "only the deleted file is counted (1)" \
  || fail "purged files wrong: $(grep '^purged_files_total=' "$RET14")"
grep -q '^archive_files=1$' "$RET14" && ok "archive_files counts regular files only" \
  || fail "archive_files wrong: $(grep '^archive_files=' "$RET14")"

section "T12 a legacy upload spool is surfaced, never sent, never deleted"
rm -rf "$TMP/base6"
mkdir -p "$TMP/base6/spool/$D45"
cp "$OCR_FIXTURE" "$TMP/base6/spool/$D45/$LEG.png"
printf -- '---\ntype: capture\n---\n\nlegacy pair\n' > "$TMP/base6/spool/$D45/$LEG.md"
LEG_PNG_SUM="$(shasum "$TMP/base6/spool/$D45/$LEG.png" | awk '{print $1}')"
LEG_MD_SUM="$(shasum "$TMP/base6/spool/$D45/$LEG.md" | awk '{print $1}')"
env GARIME_CAPTURE_HOME="$TMP/base6" "$BIN" paths >"$TMP/legacy.log" 2>&1
grep -q "ERROR: 2 file(s) left in .*spool" "$TMP/legacy.log" && ok "the legacy spool is reported loudly at startup" \
  || fail "the legacy spool was passed over silently: $(cat "$TMP/legacy.log")"
env GARIME_CAPTURE_HOME="$TMP/base6" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/legacy2.log" 2>&1
[ "$(shasum "$TMP/base6/spool/$D45/$LEG.png" | awk '{print $1}')" = "$LEG_PNG_SUM" ] \
  && ok "the legacy image is byte-for-byte untouched" || fail "the legacy image was modified or removed"
[ "$(shasum "$TMP/base6/spool/$D45/$LEG.md" | awk '{print $1}')" = "$LEG_MD_SUM" ] \
  && ok "the legacy markdown is byte-for-byte untouched" || fail "the legacy markdown was modified or removed"
[ "$(count_files "$TMP/base6/archive")" = "0" ] && ok "nothing was migrated into the archive" || fail "the legacy spool was adopted"
[ ! -s "$GARIME_NETWORK_TRIPWIRE" ] && ok "no network tool was invoked for the legacy spool" \
  || fail "a network tool ran: $(cat "$GARIME_NETWORK_TRIPWIRE")"

section "T13 images predating the first run are left in place"
rm -rf "$TMP/base2" "$TMP/watch2"
mkdir -p "$TMP/base2/registry" "$TMP/watch2"
echo $(( $(date +%s) + 600 )) > "$TMP/base2/registry/bootstrap"
make_text_shot "$TMP/watch2/pre-bootstrap.png"
PRE_SUM="$(shasum "$TMP/watch2/pre-bootstrap.png" | awk '{print $1}')"
GARIME_CAPTURE_HOME="$TMP/base2" GARIME_WATCH_DIR="$TMP/watch2" "$BIN" >"$TMP/daemon2.log" 2>&1 &
D2_PID=$!
for _ in $(seq 1 40); do grep -q 'predates this daemon' "$TMP/daemon2.log" && break; sleep 1; done
kill "$D2_PID" 2>/dev/null; wait "$D2_PID" 2>/dev/null
[ -e "$TMP/watch2/pre-bootstrap.png" ] && ok "pre-bootstrap image left on disk" || fail "daemon consumed a pre-bootstrap image"
[ "$(shasum "$TMP/watch2/pre-bootstrap.png" | awk '{print $1}')" = "$PRE_SUM" ] \
  && ok "its bytes are unchanged" || fail "the pre-bootstrap image was rewritten"
grep -q 'predates this daemon' "$TMP/daemon2.log" && ok "skip logged once with a reason" || fail "no skip log line"
[ "$(count_files "$TMP/base2/archive")" = "0" ] && ok "nothing archived" || fail "pre-bootstrap image was archived"

section "T14 a backlog image is archived under today, not born expired"
rm -rf "$TMP/base12"
make_text_shot "$TMP/shots/backlog-old.png"
touch -t "$(date -v-45d +%Y%m%d%H%M.%S)" "$TMP/shots/backlog-old.png"
SetFile -d "$(date -v-45d +'%m/%d/%Y %H:%M:%S')" "$TMP/shots/backlog-old.png" 2>/dev/null
env GARIME_CAPTURE_HOME="$TMP/base12" "$BIN" capture-once "$TMP/shots/backlog-old.png" >"$TMP/backlog.log" 2>&1 \
  && ok "capture-once ingested the old backlog image" || fail "capture-once failed: $(cat "$TMP/backlog.log")"
[ "$(find "$TMP/base12/archive/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "archived under today (the retention clock starts at archiving)" || fail "backlog image not archived under $TODAY"
[ ! -d "$TMP/base12/archive/$D45" ] && ok "no archive day 45 days in the past was created" \
  || fail "image archived into an already-expired day"
env GARIME_CAPTURE_HOME="$TMP/base12" GARIME_NOW="$NOON" "$BIN" retention-once >/dev/null 2>&1
[ "$(find "$TMP/base12/archive/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the backlog image survives the reaper" || fail "the backlog image was purged seconds after ingest"

section "T15 durability is fsync, not hope"
grep -q 'F_FULLFSYNC' "$ROOT/Sources/Support.swift" && ok "F_FULLFSYNC used for durability" || fail "no F_FULLFSYNC in Support.swift"
grep -q 'syncToDisk(url)' "$ROOT/Sources/Archive.swift" && ok "file contents fsynced after write" || fail "archive writes are not fsynced"
grep -q 'syncToDisk(archiveDayDir)' "$ROOT/Sources/Archive.swift" \
  && ok "the archive directory is fsynced before success is reported" || fail "the archive directory is not fsynced"

section "T16 installer is idempotent"
export GARIME_INSTALL_SKIP_LAUNCHCTL=1
export GARIME_BIN_DIR="$TMP/bin"
export GARIME_LAUNCH_AGENTS_DIR="$TMP/agents"
"$ROOT/install.sh" >"$TMP/install1.log" 2>&1 && ok "first install exited 0" || fail "first install failed: $(tail -3 "$TMP/install1.log")"
"$ROOT/install.sh" >"$TMP/install2.log" 2>&1 && ok "second install exited 0" || fail "second install failed: $(tail -3 "$TMP/install2.log")"
[ -x "$TMP/bin/garimecapture" ] && ok "binary installed" || fail "binary not installed"
[ -x "$TMP/bin/garimecapture-watchdog.sh" ] && ok "watchdog installed" || fail "watchdog not installed"
for label in ai.garime.capture ai.garime.capture-watchdog; do
  plutil -lint "$TMP/agents/$label.plist" >/dev/null && ok "$label.plist lints" || fail "$label.plist invalid"
  grep -q "$TMP/bin" "$TMP/agents/$label.plist" && ok "$label paths rewritten" || fail "$label paths not rewritten"
done
unset GARIME_INSTALL_SKIP_LAUNCHCTL GARIME_BIN_DIR GARIME_LAUNCH_AGENTS_DIR

section "T17 the watchdog watches only local state"
grep -qE 'upload|spool|pending_images' "$ROOT/garimecapture-watchdog.sh" \
  && fail "the watchdog still probes the retired upload stage" || ok "no upload or spool probe left in the watchdog"
export GARIME_WATCHDOG_LOG="$TMP/watchdog.log"
sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
WD_STATUS=$?
if launchctl print "gui/$UID/ai.garime.capture" >/dev/null 2>&1; then
  ok "agent is loaded on this Mac — skipping the unloaded-agent branch"
else
  [ "$WD_STATUS" -eq 1 ] && ok "watchdog exits 1 when the agent is unloaded" || fail "watchdog exit $WD_STATUS"
  grep -q 'is not loaded in launchd' "$TMP/watchdog.log" && ok "watchdog logged the missing agent" || fail "watchdog silent about missing agent"
fi
: > "$TMP/watchdog2.log"
mkdir -p "$TMP/base17/status" "$TMP/watch17"
echo 0 > "$TMP/base17/status/capture.heartbeat"
env GARIME_CAPTURE_HOME="$TMP/base17" GARIME_WATCHDOG_LOG="$TMP/watchdog2.log" GARIME_WATCHDOG_SKIP_LAUNCHCTL=1 \
  GARIME_WATCH_DIR="$TMP/watch17" sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
grep -q 'capture heartbeat stale' "$TMP/watchdog2.log" && ok "a stale capture heartbeat still alarms" \
  || fail "the watchdog went quiet on a stale capture heartbeat"
grep -q 'kickstart -k' "$GARIME_LAUNCHCTL_LOG" \
  && ok "the kickstart went to the test recorder — the suite never restarts the live agent" \
  || fail "no kickstart reached the recorder; the watchdog may be calling the real launchctl"
unset GARIME_WATCHDOG_LOG

section "T18 only a truly deterministic Vision error is allowed to consume the capture"
check_class() {
  actual="$("$BIN" ocr-classify "$1" "$2" 2>/dev/null)"
  [ "$actual" = "$3" ] && ok "$1 $2 -> $3" || fail "$1 $2 classified as '$actual', expected '$3'"
}
check_class com.apple.Vision 13 refused
for code in 1 2 3 4 5 6 7 8 9 10 11 12 14; do check_class com.apple.Vision "$code" failed; done
check_class NSPOSIXErrorDomain 13 failed
check_class NSCocoaErrorDomain 13 failed
grep -q 'VNErrorCode.invalidImage' "$ROOT/Sources/Capture.swift" \
  && ok "the deterministic class is pinned to VNErrorCode.invalidImage, not to every throw" \
  || fail "the OCR classifier no longer pins the deterministic case to VNErrorCode.invalidImage"
rm -rf "$TMP/base18"
make_shot 'tiny-refusal.png'
env GARIME_CAPTURE_HOME="$TMP/base18" "$BIN" capture-once "$TMP/shots/tiny-refusal.png" >"$TMP/refuse.log" 2>&1
grep -q 'OCR refused' "$TMP/refuse.log" \
  && ok "the real 1x1 path still reaches the refusal branch (code 13)" || fail "the 1x1 image is no longer refused"

section "T19 the retry budget is temporal, survives a restart, and primes the clipboard once"
rm -rf "$TMP/base19" "$TMP/watch19"
mkdir -p "$TMP/base19/archive" "$TMP/watch19"
chmod 500 "$TMP/base19/archive"
env GARIME_CAPTURE_HOME="$TMP/base19" GARIME_WATCH_DIR="$TMP/watch19" "$BIN" >"$TMP/retry1.log" 2>&1 &
R1=$!
for _ in $(seq 1 60); do [ -f "$TMP/base19/registry/bootstrap" ] && break; sleep 1; done
make_text_shot "$TMP/watch19/retry-case.png"
for _ in $(seq 1 90); do grep -q 'archive failed' "$TMP/retry1.log" && break; sleep 1; done
sleep 8
kill "$R1" 2>/dev/null; wait "$R1" 2>/dev/null
chmod 700 "$TMP/base19/archive"
burst="$(grep -c 'archive failed' "$TMP/retry1.log")"
[ "$burst" -ge 1 ] && [ "$burst" -le 2 ] \
  && ok "the default backoff spends $burst attempt(s) in the 8s after the first failure, not the whole budget" \
  || fail "expected 1-2 attempts within 8s of the first failure, got $burst"
grep -q 'giving up' "$TMP/retry1.log" \
  && fail "the whole retry budget burned inside 8 seconds" || ok "no give-up inside 8 seconds"
grep -q 'next attempt for retry-case.png in' "$TMP/retry1.log" \
  && ok "the daemon logs when the next attempt is due" || fail "no retry schedule logged"

rm -rf "$TMP/base19b" "$TMP/watch19b"
mkdir -p "$TMP/base19b/archive" "$TMP/watch19b"
chmod 500 "$TMP/base19b/archive"
run_doomed() {
  env GARIME_CAPTURE_HOME="$TMP/base19b" GARIME_WATCH_DIR="$TMP/watch19b" \
    GARIME_RETRY_BASE_DELAY=0.5 GARIME_RETRY_MAX_DELAY=1 "$BIN" >"$1" 2>&1 &
  echo $!
}
R2="$(run_doomed "$TMP/retry2.log")"
for _ in $(seq 1 60); do [ -f "$TMP/base19b/registry/bootstrap" ] && break; sleep 1; done
make_text_shot "$TMP/watch19b/doomed.png"
for _ in $(seq 1 90); do grep -q 'giving up' "$TMP/retry2.log" && break; sleep 1; done
sleep 2
kill "$R2" 2>/dev/null; wait "$R2" 2>/dev/null
[ "$(grep -c 'archive failed' "$TMP/retry2.log")" = "5" ] \
  && ok "the budget is exactly 5 attempts" || fail "expected 5 attempts, got $(grep -c 'archive failed' "$TMP/retry2.log")"
[ "$(grep -c 'clipboard primed' "$TMP/retry2.log")" = "1" ] \
  && ok "the clipboard is primed once, not once per retry" \
  || fail "the clipboard was primed $(grep -c 'clipboard primed' "$TMP/retry2.log") times across the retries"
[ "$(grep -c 'the clipboard stays untouched' "$TMP/retry2.log")" = "4" ] \
  && ok "every retry left the clipboard alone" || fail "a retry clobbered the clipboard"
[ -f "$TMP/watch19b/doomed.png" ] && ok "the abandoned original is still on disk" || fail "the abandoned original was deleted"
grep -qxF 'doomed.png' "$TMP/base19b/status/stranded" \
  && ok "the abandoned capture is published in status/stranded" || fail "status/stranded does not list the abandoned capture"
[ -f "$TMP/base19b/registry/failures.json" ] && ok "the failure ledger is persisted" || fail "no failure ledger on disk"

R3="$(run_doomed "$TMP/retry3.log")"
for _ in $(seq 1 90); do grep -q 'Vision model warm' "$TMP/retry3.log" && break; sleep 1; done
sleep 4
kill "$R3" 2>/dev/null; wait "$R3" 2>/dev/null
chmod 700 "$TMP/base19b/archive"
[ "$(grep -c 'archive failed' "$TMP/retry3.log")" = "0" ] \
  && ok "a restart does not refill the budget — the watchdog kickstart loop is dead" \
  || fail "the restart retried $(grep -c 'archive failed' "$TMP/retry3.log") times; the budget is not durable"
[ "$(grep -c 'clipboard primed' "$TMP/retry3.log")" = "0" ] \
  && ok "a restart does not re-clobber the clipboard" || fail "the restart primed the clipboard again"
[ -f "$TMP/watch19b/doomed.png" ] && ok "the abandoned original survives the restart" || fail "the restart consumed the abandoned original"

section "T20 the watchdog stops kickstarting over a capture the daemon gave up on"
rm -rf "$TMP/base20" "$TMP/watch20"
mkdir -p "$TMP/base20/status" "$TMP/watch20"
date +%s > "$TMP/base20/status/capture.heartbeat"
OLD_TS="$(date -v-10M +%Y%m%d%H%M.%S)"
cp "$OCR_FIXTURE" "$TMP/watch20/stranded-shot.png"
touch -t "$OLD_TS" "$TMP/watch20/stranded-shot.png"
printf 'stranded-shot.png\n' > "$TMP/base20/status/stranded"
: > "$TMP/wd20.log"
env GARIME_CAPTURE_HOME="$TMP/base20" GARIME_WATCH_DIR="$TMP/watch20" \
  GARIME_WATCHDOG_LOG="$TMP/wd20.log" GARIME_WATCHDOG_SKIP_LAUNCHCTL=1 \
  sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
grep -q 'kickstart' "$TMP/wd20.log" \
  && fail "the watchdog kickstarted over a capture a restart cannot fix" \
  || ok "a stranded capture no longer triggers a kickstart"

cp "$OCR_FIXTURE" "$TMP/watch20/live-shot.heif"
touch -t "$OLD_TS" "$TMP/watch20/live-shot.heif"
: > "$TMP/wd20b.log"
env GARIME_CAPTURE_HOME="$TMP/base20" GARIME_WATCH_DIR="$TMP/watch20" \
  GARIME_WATCHDOG_LOG="$TMP/wd20b.log" GARIME_WATCHDOG_SKIP_LAUNCHCTL=1 \
  sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
grep -q 'unconsumed screenshot' "$TMP/wd20b.log" \
  && ok "a genuinely unconsumed capture still alarms" || fail "the watchdog went blind to a real backlog"
grep -q 'live-shot.heif' "$TMP/wd20b.log" \
  && ok "the .heif is probed and the stranded entry is filtered out, not merely first in line" \
  || fail "the watchdog reported $(sed -n 's/.*unconsumed screenshot: //p' "$TMP/wd20b.log")"

section "T21 GARIME_ARCHIVE_DIR relocates only the images, and only where it is allowed"
rm -rf "$TMP/base21" "$TMP/pics21"
mkdir -p "$TMP/pics21"
make_text_shot "$TMP/shots/external-archive.png"
env GARIME_CAPTURE_HOME="$TMP/base21" GARIME_ARCHIVE_DIR="$TMP/pics21" \
  "$BIN" capture-once "$TMP/shots/external-archive.png" >"$TMP/ext.log" 2>&1 \
  && ok "capture-once archived into an external directory" || fail "external archive failed: $(cat "$TMP/ext.log")"
[ "$(find "$TMP/pics21/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the image landed in <external>/$TODAY" || fail "nothing archived under the external dir"
[ "$(count_files "$TMP/base21/archive")" = "0" ] \
  && ok "the capture home archive stayed empty" || fail "an image was written under the capture home archive"
[ -f "$TMP/base21/registry/processed.json" ] && ok "the registry still lives under the capture home" \
  || fail "the registry followed the archive"
[ "$(find "$TMP/pics21" -name 'processed.json' -o -name 'retention.status' | wc -l | tr -d ' ')" = "0" ] \
  && ok "no status or registry state leaked into the external archive" || fail "state leaked into the external archive"
env GARIME_CAPTURE_HOME="$TMP/base21" GARIME_ARCHIVE_DIR="$TMP/pics21" "$BIN" paths 2>/dev/null \
  | grep -qx "archive=$TMP/pics21" && ok "paths reports the override" || fail "paths did not report the override"
env GARIME_CAPTURE_HOME="$TMP/base21" "$BIN" paths 2>/dev/null \
  | grep -qx "archive=$TMP/base21/archive" && ok "without the variable the default is unchanged" \
  || fail "the default archive path moved"

for bad_dir in "$HOME/Gabriel/garimecapture-archive-$$" "$HOME/Sistema/garimecapture-archive-$$" \
               "$HOME/Vault/garimecapture-archive-$$" "$HOME/Library/Application Support/Geo/cap-$$"; do
  env GARIME_CAPTURE_HOME="$TMP/base21" GARIME_ARCHIVE_DIR="$bad_dir" "$BIN" paths >"$TMP/badarch.log" 2>&1
  STATUS=$?
  [ "$STATUS" -eq 78 ] && ok "exit 78 for an archive dir inside $(dirname "$bad_dir")" \
    || fail "forbidden archive dir $bad_dir accepted (exit $STATUS)"
  [ ! -e "$bad_dir" ] && ok "nothing created at $bad_dir" || fail "the guard created $bad_dir"
done
ln -sfn "$HOME/Gabriel" "$TMP/vault-link"
env GARIME_CAPTURE_HOME="$TMP/base21" GARIME_ARCHIVE_DIR="$TMP/vault-link/cap-$$" "$BIN" paths >"$TMP/badarch2.log" 2>&1
STATUS=$?
[ "$STATUS" -eq 78 ] && ok "a symlink into ~/Gabriel is refused too" || fail "symlinked archive dir accepted (exit $STATUS)"
[ ! -e "$HOME/Gabriel/cap-$$" ] && ok "nothing created through the symlink" || fail "the symlink guard leaked into ~/Gabriel"
env GARIME_CAPTURE_HOME="$TMP/base21" GARIME_ARCHIVE_DIR="$HOME" "$BIN" paths >/dev/null 2>&1
[ "$?" -eq 78 ] && ok "the home directory itself is refused as an archive root" || fail "\$HOME accepted as archive root"
VAULT_AFTER21="$(vault_count)"
[ "$VAULT_BEFORE" = "$VAULT_AFTER21" ] && ok "~/Gabriel still untouched ($VAULT_AFTER21 files)" \
  || fail "~/Gabriel changed: $VAULT_BEFORE -> $VAULT_AFTER21"

section "T22 the archive root may be the watch dir: no re-ingest, no purge of loose files"
rm -rf "$TMP/base22" "$TMP/pics22"
mkdir -p "$TMP/pics22"
env GARIME_CAPTURE_HOME="$TMP/base22" GARIME_ARCHIVE_DIR="$TMP/pics22" GARIME_WATCH_DIR="$TMP/pics22" \
  "$BIN" >"$TMP/daemon22.log" 2>&1 &
D22=$!
for _ in $(seq 1 60); do [ -f "$TMP/base22/registry/bootstrap" ] && break; sleep 1; done
make_text_shot "$TMP/pics22/same-root.png"
for _ in $(seq 1 60); do
  [ "$(find "$TMP/pics22/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 1
done
sleep 5
kill "$D22" 2>/dev/null; wait "$D22" 2>/dev/null
[ "$(find "$TMP/pics22/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "exactly one archived image; the day folder is not rescanned" \
  || fail "re-ingest loop: $(find "$TMP/pics22" -type f -name '*.png' | wc -l | tr -d ' ') file(s) archived"
[ ! -e "$TMP/pics22/same-root.png" ] && ok "the original was consumed from the shared root" || fail "original left in the shared root"
[ "$(grep -c 'archived ' "$TMP/daemon22.log")" = "1" ] && ok "a single ingest was logged" \
  || fail "$(grep -c 'archived ' "$TMP/daemon22.log") ingests logged for one screenshot"

make_text_shot "$TMP/pics22/pending-loose.png"
printf 'user file' > "$TMP/pics22/NOTES.txt"
mkdir -p "$TMP/pics22/$D45"
cp "$OCR_FIXTURE" "$TMP/pics22/$D45/$LEG.png"
PENDING_SUM="$(shasum "$TMP/pics22/pending-loose.png" | awk '{print $1}')"
env GARIME_CAPTURE_HOME="$TMP/base22" GARIME_ARCHIVE_DIR="$TMP/pics22" GARIME_NOW="$NOON" \
  "$BIN" retention-once >"$TMP/retention22.log" 2>&1 \
  && ok "retention-once exited 0 on the shared root" || fail "retention failed: $(cat "$TMP/retention22.log")"
[ -f "$TMP/pics22/pending-loose.png" ] && [ "$(shasum "$TMP/pics22/pending-loose.png" | awk '{print $1}')" = "$PENDING_SUM" ] \
  && ok "a loose screenshot waiting in the archive root is untouched" || fail "the reaper ate a pending screenshot"
[ -f "$TMP/pics22/NOTES.txt" ] && ok "a foreign file in the archive root is untouched" || fail "NOTES.txt was deleted"
[ ! -e "$TMP/pics22/$D45" ] && ok "the expired day folder is still purged" || fail "the expired day survived"
[ -d "$TMP/pics22/$TODAY" ] && ok "today's archive day is kept" || fail "today's day folder was purged"

section "T23 the installer carries GARIME_ARCHIVE_DIR without inventing a default"
export GARIME_INSTALL_SKIP_LAUNCHCTL=1
export GARIME_BIN_DIR="$TMP/bin23"
export GARIME_LAUNCH_AGENTS_DIR="$TMP/agents23"
CAP_PLIST="$TMP/agents23/ai.garime.capture.plist"
"$ROOT/install.sh" >"$TMP/install23a.log" 2>&1 && ok "install without the variable exited 0" \
  || fail "install failed: $(tail -3 "$TMP/install23a.log")"
plutil -extract EnvironmentVariables raw -o - "$CAP_PLIST" >/dev/null 2>&1 \
  && fail "a plain install invented an EnvironmentVariables default" \
  || ok "a plain install writes no EnvironmentVariables key"
GARIME_ARCHIVE_LAYOUT=flat GARIME_ARCHIVE_DIR="$TMP/pics23" "$ROOT/install.sh" >"$TMP/install23b.log" 2>&1 \
  && ok "install with GARIME_ARCHIVE_DIR exited 0" || fail "install failed: $(tail -3 "$TMP/install23b.log")"
[ "$(plutil -extract EnvironmentVariables.GARIME_ARCHIVE_DIR raw -o - "$CAP_PLIST" 2>/dev/null)" = "$TMP/pics23" ] \
  && ok "the agent carries the requested archive dir" || fail "the archive dir was not written into the agent"
"$ROOT/install.sh" >"$TMP/install23c.log" 2>&1 && ok "reinstall without the variable exited 0" \
  || fail "reinstall failed: $(tail -3 "$TMP/install23c.log")"
[ "$(plutil -extract EnvironmentVariables.GARIME_ARCHIVE_DIR raw -o - "$CAP_PLIST" 2>/dev/null)" = "$TMP/pics23" ] \
  && ok "a later install preserves it instead of silently reverting the archive" \
  || fail "the reinstall dropped GARIME_ARCHIVE_DIR"
[ "$(plutil -extract EnvironmentVariables.GARIME_ARCHIVE_LAYOUT raw -o - "$CAP_PLIST" 2>/dev/null)" = "flat" ]   && ok "reinstall preserves flat layout" || fail "layout lost on reinstall"
plutil -lint "$CAP_PLIST" >/dev/null && ok "the rewritten agent still lints" || fail "the agent plist is invalid"
plutil -extract EnvironmentVariables raw -o - "$TMP/agents23/ai.garime.capture-watchdog.plist" >/dev/null 2>&1 \
  && fail "the watchdog agent got an archive override it does not use" \
  || ok "the watchdog agent is left alone"
PLIST_BEFORE_BAD_INSTALL="$(shasum "$CAP_PLIST")"
GARIME_ARCHIVE_DIR="relative/path" "$ROOT/install.sh" >"$TMP/install23d.log" 2>&1 \
  && fail "a relative GARIME_ARCHIVE_DIR was accepted" || ok "a relative GARIME_ARCHIVE_DIR is rejected"
[ "$(shasum "$CAP_PLIST")" = "$PLIST_BEFORE_BAD_INSTALL" ] \
  && ok "invalid configuration leaves the installed agent untouched" || fail "invalid install replaced the agent"
grep -q 'GARIME_ARCHIVE_DIR' "$ROOT/ai.garime.capture.plist" \
  && fail "the shipped template hardcodes an archive dir" || ok "the shipped template stays default-free"
mkdir -p "$TMP/invalid-bin"
cat > "$TMP/invalid-bin/launchctl" <<'RECORDER'
#!/bin/sh
echo "$*" >> "$GARIME_LAUNCHCTL_LOG"
exit 1
RECORDER
chmod +x "$TMP/invalid-bin/launchctl"
: > "$GARIME_LAUNCHCTL_LOG"
GARIME_INSTALL_SKIP_LAUNCHCTL=0 GARIME_ARCHIVE_LAYOUT=invalid PATH="$TMP/invalid-bin:$PATH"   "$ROOT/install.sh" >"$TMP/invalid-layout.log" 2>&1   && fail "invalid layout accepted" || ok "invalid layout rejected"
[ ! -s "$GARIME_LAUNCHCTL_LOG" ] && ok "invalid layout never touches launchctl" || fail "invalid layout touched services"
[ "$(shasum "$CAP_PLIST")" = "$PLIST_BEFORE_BAD_INSTALL" ]   && ok "invalid layout leaves installed plist unchanged" || fail "invalid layout replaced plist"
unset GARIME_INSTALL_SKIP_LAUNCHCTL GARIME_BIN_DIR GARIME_LAUNCH_AGENTS_DIR

section "T24 a user-visible archive never follows a symlink at a day path"
mkdir -p "$TMP/pics24" "$TMP/outside24"
ln -s "$TMP/outside24" "$TMP/pics24/$TODAY"
make_text_shot "$TMP/shots/day-link.png"
env GARIME_CAPTURE_HOME="$TMP/base24" GARIME_ARCHIVE_DIR="$TMP/pics24" \
  "$BIN" capture-once "$TMP/shots/day-link.png" >"$TMP/day-link.log" 2>&1 \
  && fail "the archive followed a symlink at the day path" || ok "a symlinked day path is refused"
[ -f "$TMP/shots/day-link.png" ] && ok "the original survives an unsafe archive day" || fail "original lost"
[ "$(count_files "$TMP/outside24")" = "0" ] && ok "no image written outside the archive" || fail "write escaped the archive"
ln -s "$HOME" "$TMP/home-link24"
env GARIME_CAPTURE_HOME="$TMP/base24" GARIME_ARCHIVE_DIR="$TMP/home-link24" "$BIN" paths >/dev/null 2>&1
[ "$?" -eq 78 ] && ok "a symlink to the home root is also refused" || fail "home-root alias accepted"

section "T25 flat shared-root daemon: OCR, one root artifact, no loop"
mkdir -p "$TMP/flat" "$TMP/base25/registry"
echo 1 > "$TMP/base25/registry/bootstrap"
make_text_shot "$TMP/flat/native.png"
touch -t "$(date -v-45d +%Y%m%d%H%M.%S)" "$TMP/flat/native.png"
SetFile -d "$(date -v-45d +'%m/%d/%Y %H:%M:%S')" "$TMP/flat/native.png" 2>/dev/null
env GARIME_CAPTURE_HOME="$TMP/base25" GARIME_ARCHIVE_DIR="$TMP/flat" GARIME_ARCHIVE_LAYOUT=flat   GARIME_WATCH_DIR="$TMP/flat" "$BIN" >"$TMP/flat.log" 2>&1 &
D25=$!
for _ in $(seq 1 60); do [ ! -e "$TMP/flat/native.png" ] && break; sleep 1; done
sleep 5
kill "$D25" 2>/dev/null; wait "$D25" 2>/dev/null
[ ! -e "$TMP/flat/native.png" ] && ok "flat consumes original" || fail "flat original remains"
[ "$(find "$TMP/flat" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "1" ]   && ok "one root artifact" || fail "flat artifact count"
[ "$(find "$TMP/flat" -mindepth 1 -type d | wc -l | tr -d ' ')" = "0" ]   && ok "no daily directories" || fail "flat made directories"
[ "$(grep -c 'archived ' "$TMP/flat.log")" = "1" ] && ok "no re-ingest" || fail "flat ingest loop"
"$BIN" clipboard-show | grep -q "^string=.*$OCR_TEXT" && ok "flat OCR clipboard" || fail "flat OCR missing"
if grep -rlI "$OCR_TEXT" "$TMP/base25" "$TMP/flat.log" >/dev/null; then fail "flat OCR leaked"; else ok "no flat OCR persisted"; fi
FLAT_CURRENT="$(find "$TMP/flat" -maxdepth 1 -type f | head -1)"
[ "$(stat -f %m "$FLAT_CURRENT")" -gt "$(( $(date +%s) - 60 ))" ]   && ok "backlog archive mtime is now, not capture time" || fail "flat age inherits capture time"

section "T26 flat retention ignores native files, foreign files, symlinks and all subdirectories"
cp "$OCR_FIXTURE" "$TMP/flat/$LEG.png"
cp "$OCR_FIXTURE" "$TMP/flat/pending-native.png"
printf 'foreign' > "$TMP/flat/NOTES.txt"
mkdir -p "$TMP/flat/$D45" "$TMP/flat/nested" "$TMP/base25/archive/$D45"
cp "$OCR_FIXTURE" "$TMP/flat/$D45/$LEG.png"
cp "$OCR_FIXTURE" "$TMP/flat/nested/$LEG.png"
cp "$OCR_FIXTURE" "$TMP/base25/archive/$D45/$LEG.png"
ln -s "$TMP/flat/pending-native.png" "$TMP/flat/$LEG2.png"
for f in "$LEG.png" pending-native.png NOTES.txt; do touch -t "$(date -v-45d +%Y%m%d%H%M.%S)" "$TMP/flat/$f"; done
env GARIME_CAPTURE_HOME="$TMP/base25" GARIME_ARCHIVE_DIR="$TMP/flat" GARIME_ARCHIVE_LAYOUT=flat   "$BIN" retention-once >"$TMP/flat-retention.log" 2>&1 && ok "flat retention succeeds" || fail "flat retention failed"
[ ! -e "$TMP/flat/$LEG.png" ] && ok "expired flat artifact purged" || fail "expired flat remains"
for f in "$FLAT_CURRENT" "$TMP/flat/pending-native.png" "$TMP/flat/NOTES.txt"   "$TMP/flat/$D45/$LEG.png" "$TMP/flat/nested/$LEG.png" "$TMP/base25/archive/$D45/$LEG.png"; do
  [ -f "$f" ] && ok "kept $f" || fail "lost $f"
done
[ -L "$TMP/flat/$LEG2.png" ] && ok "flat symlink kept" || fail "flat symlink lost"
for field in archive_days=0 archive_files=1 archive_oldest_age_days=0 purged_files_total=1 purged_days_total=0; do
  grep -qx "$field" "$TMP/base25/status/retention.status" && ok "$field" || fail "wrong $field"
done
# An archived file older than the watchdog's backlog threshold must not cause a restart.
touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$FLAT_CURRENT"
rm "$TMP/flat/pending-native.png" "$TMP/flat/$LEG2.png"
env GARIME_CAPTURE_HOME="$TMP/base25" GARIME_WATCH_DIR="$TMP/flat"   GARIME_WATCHDOG_LOG="$TMP/wd25.log" GARIME_WATCHDOG_SKIP_LAUNCHCTL=1   sh "$ROOT/garimecapture-watchdog.sh"
grep -q kickstart "$TMP/wd25.log" && fail "watchdog mistakes archive for backlog" || ok "watchdog ignores flat artifact"
env GARIME_CAPTURE_HOME="$TMP/invalid-layout-base" GARIME_ARCHIVE_LAYOUT=invalid "$BIN" paths >/dev/null 2>&1
[ "$?" -eq 78 ] && ok "daemon rejects invalid layout" || fail "daemon accepts invalid layout"
[ ! -e "$TMP/invalid-layout-base" ] && ok "invalid layout creates nothing" || fail "invalid layout wrote state"

echo
[ ! -s "$GARIME_NETWORK_TRIPWIRE" ] || { fail "network tool invoked during the run: $(cat "$GARIME_NETWORK_TRIPWIRE")"; }
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL GREEN"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
