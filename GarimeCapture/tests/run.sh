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
cp "$ROOT/tests/fake-bin/ssh" "$ROOT/tests/fake-bin/scp" "$TMP/fake-bin/"
chmod 755 "$TMP/fake-bin/ssh" "$TMP/fake-bin/scp"
printf 'not-a-real-key\n' > "$TMP/fake-key"

export GARIME_CAPTURE_HOME="$TMP/base"
export GARIME_REMOTE_HOST="garime"
export GARIME_REMOTE_ROOT="$TMP/remote"
export GARIME_SSH_BIN="$TMP/fake-bin/ssh"
export GARIME_SCP_BIN="$TMP/fake-bin/scp"
export GARIME_SSH_KEY="$TMP/fake-key"
export GARIME_FAKE_LOG="$TMP/argv.log"
export GARIME_CONNECT_TIMEOUT=7
: > "$GARIME_FAKE_LOG"

SPOOL="$TMP/base/spool"
ARCHIVE="$TMP/base/archive"
REMOTE="$TMP/remote"
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

vault_count() {
  [ -d "$HOME/Vault/Captures" ] || { echo 0; return; }
  find "$HOME/Vault/Captures" -type f 2>/dev/null | wc -l | tr -d ' '
}
VAULT_BEFORE="$(vault_count)"

make_shot() { printf '%s' "$PNG_B64" | base64 --decode > "$TMP/shots/$1"; }

section "T1 hostile filenames are sanitized before they reach the spool"
cd "$TMP"
PWNED="$TMP/pwned-marker"
make_shot '`touch pwned-marker`.png'
make_shot '$(touch pwned-marker).png'
make_shot '-oProxyCommand=evil.png'
make_shot '..--..--etc--passwd.png'
make_shot 'name with spaces & $HOME.png'

find "$TMP/shots" -type f -print0 | xargs -0 "$BIN" spool-add >/dev/null 2>&1
if [ -e "$PWNED" ]; then fail "hostile filename was evaluated by a shell"; else ok "no shell evaluation of filenames"; fi

remaining="$(find "$TMP/shots" -type f | wc -l | tr -d ' ')"
[ "$remaining" = "0" ] && ok "originals removed after durable spool" || fail "originals left behind: $remaining"

spooled="$(find "$SPOOL/$TODAY" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$spooled" = "5" ] && ok "5 markdown files spooled for upload" || fail "expected 5 spooled files, got $spooled"

stray="$(find "$SPOOL" -type f ! -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$stray" = "0" ] && ok "no image ever sits in the upload spool" || fail "$stray image(s) in the spool"

archived="$(find "$ARCHIVE/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$archived" = "5" ] && ok "5 images kept in the local archive" || fail "expected 5 archived images, got $archived"

bad=0
while IFS= read -r f; do
  name="$(basename "$f")"
  echo "$name" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|md)$' || { fail "unsafe spool name: $name"; bad=1; }
done < <(find "$SPOOL/$TODAY" "$ARCHIVE/$TODAY" -type f)
[ "$bad" = "0" ] && ok "every spool and archive name matches the safe whitelist"

section "T2 upload publishes to the remote and prunes the spool"
if "$BIN" upload-once >"$TMP/upload1.log" 2>&1; then ok "upload-once exited 0"; else fail "upload-once failed: $(cat "$TMP/upload1.log")"; fi

published="$(find "$REMOTE/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$published" = "5" ] && ok "5 markdown files landed in $REMOTE/$TODAY" || fail "expected 5 published files, got $published"

remote_images="$(find "$REMOTE" -type f ! -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$remote_images" = "0" ] && ok "no image reached the remote vault" || fail "$remote_images image(s) uploaded to the remote"

left="$(find "$SPOOL" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok "spool pruned only after confirmed upload" || fail "spool still holds $left file(s)"

survivors="$(find "$ARCHIVE/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$survivors" = "5" ] && ok "archived images survive the upload" || fail "expected 5 archived images after upload, got $survivors"

[ -d "$REMOTE/$TODAY/.incoming" ] && ok "staging dir used for atomic publish" || fail "no .incoming staging dir"

section "T3 argv hygiene"
grep -q 'arg: BatchMode=yes' "$GARIME_FAKE_LOG" && ok "BatchMode=yes present" || fail "BatchMode=yes missing"
grep -q 'arg: ConnectTimeout=7' "$GARIME_FAKE_LOG" && ok "ConnectTimeout honoured" || fail "ConnectTimeout missing"
grep -q 'arg: IdentitiesOnly=yes' "$GARIME_FAKE_LOG" && ok "IdentitiesOnly=yes present" || fail "IdentitiesOnly missing"
grep -q "arg: $TMP/fake-key" "$GARIME_FAKE_LOG" && ok "explicit identity passed" || fail "identity not passed"
grep -q 'arg: ServerAliveInterval=15' "$GARIME_FAKE_LOG" && ok "ServerAliveInterval present" || fail "ServerAliveInterval missing"
if grep -qE 'arg: .*(`|\$\()' "$GARIME_FAKE_LOG"; then
  fail "shell metacharacters reached argv"
else
  ok "no shell metacharacters in any argv element"
fi

if grep -qE "^arg: garime:.*'" "$GARIME_FAKE_LOG"; then
  fail "scp destination is shell-quoted — modern scp speaks SFTP and takes the path literally"
else
  ok "scp destination passed unquoted (SFTP-safe)"
fi
grep -qE "^arg: garime:$TMP/remote/$TODAY/\.incoming/$" "$GARIME_FAKE_LOG" \
  && ok "scp destination is the literal .incoming path" || fail "unexpected scp destination"

section "T4 transient failure keeps the spool intact and never re-runs OCR"
make_shot 'retry-case.png'
"$BIN" spool-add "$TMP/shots/retry-case.png" >/dev/null 2>&1
MD="$(find "$SPOOL/$TODAY" -name '*.md' | head -1)"
[ -n "$MD" ] || fail "no markdown spooled for retry case"
MD_SUM_BEFORE="$(shasum "$MD" | awk '{print $1}')"
MD_MTIME_BEFORE="$(stat -f %m "$MD")"

GARIME_FAKE_EXIT=255 "$BIN" upload-once >"$TMP/upload2.log" 2>&1
STATUS=$?
[ "$STATUS" -ne 0 ] && ok "upload-once reports failure" || fail "upload-once masked a failure"

still="$(find "$SPOOL/$TODAY" -type f | wc -l | tr -d ' ')"
[ "$still" = "1" ] && ok "spool intact after failed upload" || fail "spool damaged: $still file(s)"
[ "$(shasum "$MD" | awk '{print $1}')" = "$MD_SUM_BEFORE" ] && ok "markdown unchanged (no OCR redo)" || fail "markdown rewritten on retry"
[ "$(stat -f %m "$MD")" = "$MD_MTIME_BEFORE" ] && ok "markdown mtime unchanged" || fail "markdown touched on retry"

if "$BIN" upload-once >"$TMP/upload3.log" 2>&1; then ok "retry drained the spool"; else fail "retry did not drain"; fi
left="$(find "$SPOOL" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok "spool empty after successful retry" || fail "spool still holds $left file(s)"

section "T5 a stalled remote is bounded, not a hang"
make_shot 'stall-case.png'
"$BIN" spool-add "$TMP/shots/stall-case.png" >/dev/null 2>&1
START="$(date +%s)"
GARIME_FAKE_SLEEP=30 GARIME_SSH_TIMEOUT=2 "$BIN" upload-once >"$TMP/upload4.log" 2>&1
STATUS=$?
ELAPSED=$(( $(date +%s) - START ))
[ "$STATUS" -ne 0 ] && ok "stalled upload reported as failure" || fail "stalled upload reported success"
[ "$ELAPSED" -lt 15 ] && ok "bounded in ${ELAPSED}s (timeout 2s)" || fail "took ${ELAPSED}s — not bounded"
grep -q 'timeout after 2s' "$TMP/upload4.log" && ok "timeout logged" || fail "no timeout log line"
still="$(find "$SPOOL/$TODAY" -type f | wc -l | tr -d ' ')"
[ "$still" = "1" ] && ok "spool preserved through the stall" || fail "spool damaged by stall: $still"

section "T6 the ~/Vault guard refuses to run"
GARIME_CAPTURE_HOME="$HOME/Vault/garimecapture-guard-$$" "$BIN" paths >"$TMP/guard.log" 2>&1
STATUS=$?
[ "$STATUS" -eq 78 ] && ok "exits 78 when the capture home resolves into ~/Vault" || fail "guard did not trigger (exit $STATUS)"
[ ! -d "$HOME/Vault/garimecapture-guard-$$" ] && ok "nothing created under ~/Vault" || fail "guard created a dir in ~/Vault"
grep -q 'forbidden vault root' "$TMP/guard.log" && ok "guard logged the refusal" || fail "guard did not log"

VAULT_AFTER="$(vault_count)"
[ "$VAULT_BEFORE" = "$VAULT_AFTER" ] && ok "~/Vault/Captures untouched ($VAULT_AFTER files)" || fail "~/Vault/Captures changed: $VAULT_BEFORE -> $VAULT_AFTER"

section "T7 watchdog reports an unloaded agent instead of failing silently"
export GARIME_WATCHDOG_LOG="$TMP/watchdog.log"
sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
WD_STATUS=$?
if launchctl print "gui/$UID/ai.garime.capture" >/dev/null 2>&1; then
  ok "agent is loaded on this Mac — skipping the unloaded-agent branch"
else
  [ "$WD_STATUS" -eq 1 ] && ok "watchdog exits 1 when the agent is unloaded" || fail "watchdog exit $WD_STATUS"
  grep -q 'is not loaded in launchd' "$TMP/watchdog.log" && ok "watchdog logged the missing agent" || fail "watchdog silent about missing agent"
fi
unset GARIME_WATCHDOG_LOG

section "T9 the real daemon loop: watch -> OCR -> spool -> upload"
rm -rf "$TMP/base/spool" "$TMP/base/archive" "$TMP/remote" "$TMP/watch"
mkdir -p "$TMP/watch"
GARIME_WATCH_DIR="$TMP/watch" GARIME_UPLOAD_INTERVAL=2 "$BIN" >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 3
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/watch/daemon-case.png"

for _ in $(seq 1 40); do
  published="$(find "$TMP/remote/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  pending="$(find "$TMP/base/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$published" -ge 1 ] && [ "$pending" -eq 0 ] && break
  sleep 1
done
kill "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null

delivered="$(find "$TMP/remote/$TODAY" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$delivered" = "1" ] && ok "daemon delivered the markdown end to end" || fail "expected 1 delivered markdown, got $delivered"
remote_images="$(find "$TMP/remote" -type f ! -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$remote_images" = "0" ] && ok "daemon uploaded no image" || fail "daemon uploaded $remote_images image(s)"
kept="$(find "$TMP/base/archive/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$kept" = "1" ] && ok "daemon kept the image in the local archive" || fail "expected 1 archived image, got $kept"
[ ! -e "$TMP/watch/daemon-case.png" ] && ok "original consumed by the daemon" || fail "original left in the watch dir"
left="$(find "$TMP/base/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok "daemon pruned the spool after upload" || fail "spool holds $left file(s)"
[ -f "$TMP/base/status/capture.heartbeat" ] && ok "capture heartbeat written" || fail "no capture heartbeat"
[ -f "$TMP/base/status/upload.heartbeat" ] && ok "upload heartbeat written" || fail "no upload heartbeat"
[ -f "$TMP/base/status/retention.heartbeat" ] && ok "retention heartbeat written" || fail "no retention heartbeat"
grep -q 'Vision model warm' "$TMP/daemon.log" && ok "Vision OCR ran in-process" || fail "no Vision warm-up"

section "T8 installer is idempotent"
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

section "T10 a half-written atomic temp is never published"
rm -rf "$SPOOL" "$ARCHIVE" "$REMOTE"
make_shot 'temp-case.png'
"$BIN" spool-add "$TMP/shots/temp-case.png" >/dev/null 2>&1
MD_FILE="$(find "$SPOOL/$TODAY" -name '*.md' | head -1)"
TEMP_NAME="$(basename "$MD_FILE").sb-7e736f51-N6HG8B"
printf 'PARTIAL-GARBAGE' > "$SPOOL/$TODAY/$TEMP_NAME"
"$BIN" upload-once >"$TMP/upload5.log" 2>&1 && ok "upload-once exited 0 alongside a temp file" || fail "upload-once failed: $(cat "$TMP/upload5.log")"

[ -e "$REMOTE/$TODAY/$TEMP_NAME" ] && fail "atomic temp file was published into the vault" || ok "atomic temp file never reached the remote"
[ -e "$SPOOL/$TODAY/$TEMP_NAME" ] && ok "atomic temp left untouched for its writer" || fail "uploader unlinked another thread's temp file"
published="$(find "$REMOTE/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$published" = "1" ] && ok "only the real markdown was published" || fail "expected 1 published file, got $published"
grep -q 'skipping foreign file' "$TMP/upload5.log" && ok "foreign spool file logged" || fail "foreign file skipped silently"
rm -rf "$SPOOL" "$ARCHIVE" "$REMOTE"

section "T11 archived image and spooled markdown are fsynced before the original is deleted"
grep -q 'F_FULLFSYNC' "$ROOT/Sources/Support.swift" && ok "F_FULLFSYNC used for durability" || fail "no F_FULLFSYNC in Support.swift"
grep -q 'syncToDisk(url)' "$ROOT/Sources/Spool.swift" && ok "file contents fsynced after write" || fail "spool writes are not fsynced"
grep -q 'syncToDisk(archiveDayDir)' "$ROOT/Sources/Spool.swift" && ok "archive directory fsynced before success is reported" || fail "archive directory is not fsynced"
grep -q 'syncToDisk(spoolDayDir)' "$ROOT/Sources/Spool.swift" && ok "spool directory fsynced before success is reported" || fail "spool directory is not fsynced"

section "T12 a permanently failing uploader is loud, not silently green"
make_shot 'alarm-case.png'
"$BIN" spool-add "$TMP/shots/alarm-case.png" >/dev/null 2>&1
GARIME_FAKE_EXIT=255 "$BIN" upload-once >"$TMP/upload6.log" 2>&1
GARIME_FAKE_EXIT=255 "$BIN" upload-once >>"$TMP/upload6.log" 2>&1
STATUS_FILE="$TMP/base/status/upload.status"
[ -f "$STATUS_FILE" ] && ok "upload.status written" || fail "no upload.status file"
grep -q '^failures=2$' "$STATUS_FILE" && ok "consecutive failures counted (2)" || fail "failure counter wrong: $(grep '^failures=' "$STATUS_FILE")"
grep -q '^spool_files=1$' "$STATUS_FILE" && ok "pending markdown depth exported" || fail "spool depth wrong: $(grep '^spool_files=' "$STATUS_FILE")"
grep -q '^spool_oldest_age=' "$STATUS_FILE" && ok "oldest spool age exported" || fail "no oldest spool age"

export GARIME_WATCHDOG_LOG="$TMP/watchdog2.log"
export GARIME_WATCHDOG_SKIP_LAUNCHCTL=1
: > "$GARIME_WATCHDOG_LOG"
date +%s > "$TMP/base/status/capture.heartbeat"
date +%s > "$TMP/base/status/upload.heartbeat"
sed "s/^last_success=.*/last_success=$(( $(date +%s) - 7200 ))/" "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
GARIME_WATCH_DIR="$TMP/shots" sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
WD_STATUS=$?
[ "$WD_STATUS" -eq 2 ] && ok "watchdog exits 2 on a stalled uploader with a fresh heartbeat" || fail "watchdog exit $WD_STATUS (heartbeat masked the stall)"
grep -q 'upload not progressing' "$GARIME_WATCHDOG_LOG" && ok "watchdog logged the forward-progress stall" || fail "watchdog silent about the stall"

: > "$GARIME_WATCHDOG_LOG"
sed -e "s/^last_success=.*/last_success=$(date +%s)/" -e 's/^failures=.*/failures=12/' "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
GARIME_WATCH_DIR="$TMP/shots" sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
[ $? -eq 2 ] && ok "watchdog exits 2 on a high consecutive-failure count" || fail "failure-count alarm did not fire"
grep -q 'uploader failing' "$GARIME_WATCHDOG_LOG" && ok "watchdog logged the failure count" || fail "watchdog silent about failure count"
unset GARIME_WATCHDOG_LOG GARIME_WATCHDOG_SKIP_LAUNCHCTL

"$BIN" upload-once >/dev/null 2>&1
grep -q '^failures=0$' "$STATUS_FILE" && ok "failure counter resets after a good pass" || fail "counter stuck after recovery"
rm -rf "$SPOOL" "$ARCHIVE" "$REMOTE"

section "T13 images predating the first run are left in place"
rm -rf "$TMP/base2" "$TMP/watch2"
mkdir -p "$TMP/base2/registry" "$TMP/watch2"
echo $(( $(date +%s) + 600 )) > "$TMP/base2/registry/bootstrap"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/watch2/pre-bootstrap.png"
GARIME_CAPTURE_HOME="$TMP/base2" GARIME_WATCH_DIR="$TMP/watch2" GARIME_UPLOAD_INTERVAL=2 \
  "$BIN" >"$TMP/daemon2.log" 2>&1 &
D2_PID=$!
for _ in $(seq 1 25); do grep -q 'predates this daemon' "$TMP/daemon2.log" && break; sleep 1; done
kill "$D2_PID" 2>/dev/null; wait "$D2_PID" 2>/dev/null
[ -e "$TMP/watch2/pre-bootstrap.png" ] && ok "pre-bootstrap image left on disk" || fail "daemon consumed a pre-bootstrap image"
grep -q 'predates this daemon' "$TMP/daemon2.log" && ok "skip logged once with a reason" || fail "no skip log line"
[ "$(find "$TMP/base2/spool" -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && ok "nothing spooled" || fail "pre-bootstrap image was spooled"
[ "$(find "$TMP/base2/archive" -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && ok "nothing archived either" || fail "pre-bootstrap image was archived"

section "T14 backlog older than an hour still drains after downtime"
rm -rf "$TMP/base3" "$TMP/watch3" "$TMP/remote3"
mkdir -p "$TMP/base3/registry" "$TMP/watch3"
echo $(( $(date +%s) - 604800 )) > "$TMP/base3/registry/bootstrap"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/watch3/backlog.png"
SetFile -d "$(date -v-2H +'%m/%d/%Y %H:%M:%S')" "$TMP/watch3/backlog.png"
touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$TMP/watch3/backlog.png"
AGE_H="$(( ( $(date +%s) - $(stat -f %B "$TMP/watch3/backlog.png") ) / 60 ))"
[ "$AGE_H" -ge 60 ] && ok "fixture is ${AGE_H}min old (beyond the retired 60min window)" || fail "fixture only ${AGE_H}min old"
GARIME_CAPTURE_HOME="$TMP/base3" GARIME_WATCH_DIR="$TMP/watch3" GARIME_REMOTE_ROOT="$TMP/remote3" GARIME_UPLOAD_INTERVAL=2 \
  "$BIN" >"$TMP/daemon3.log" 2>&1 &
D3_PID=$!
BACKLOG_DAY="$(date -v-2H +%Y-%m-%d)"
for _ in $(seq 1 40); do
  [ "$(find "$TMP/remote3/$BACKLOG_DAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 1
done
kill "$D3_PID" 2>/dev/null; wait "$D3_PID" 2>/dev/null
delivered="$(find "$TMP/remote3/$BACKLOG_DAY" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$delivered" = "1" ] && ok "2h-old backlog markdown delivered end to end" || fail "expected 1 delivered markdown, got $delivered"
[ "$(find "$TMP/base3/archive/$BACKLOG_DAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "backlog image archived locally" || fail "backlog image not archived"
[ ! -e "$TMP/watch3/backlog.png" ] && ok "backlog original consumed" || fail "backlog original abandoned"

section "T16 no image path ever reaches ssh/scp argv"
rm -rf "$TMP/base5" "$TMP/remote5"
mkdir -p "$TMP/base5"
make_shot 'argv-case.png'
: > "$TMP/argv5.log"
env GARIME_CAPTURE_HOME="$TMP/base5" GARIME_REMOTE_ROOT="$TMP/remote5" GARIME_FAKE_LOG="$TMP/argv5.log" \
  "$BIN" spool-add "$TMP/shots/argv-case.png" >/dev/null 2>&1
if env GARIME_CAPTURE_HOME="$TMP/base5" GARIME_REMOTE_ROOT="$TMP/remote5" GARIME_FAKE_LOG="$TMP/argv5.log" \
  "$BIN" upload-once >"$TMP/upload7.log" 2>&1; then ok "upload-once exited 0"; else fail "upload-once failed: $(cat "$TMP/upload7.log")"; fi

if grep -qE '^arg: .*\.(png|jpg|jpeg|heic|heif)$' "$TMP/argv5.log"; then
  fail "an image path was handed to ssh/scp"
else
  ok "zero image paths in the ssh/scp argv"
fi
grep -qE '^arg: .*\.md$' "$TMP/argv5.log" && ok "the markdown path is what gets copied" || fail "no markdown path in argv"
if grep -qE '^arg: .*\brm\b' "$TMP/argv5.log"; then
  fail "a remote delete was issued"
else
  ok "no remote delete command is ever issued"
fi
[ "$(find "$TMP/base5/archive" -type f -name '*.png' | wc -l | tr -d ' ')" = "1" ] \
  && ok "the image stayed on the Mac" || fail "image missing from the archive"

section "T17 a legacy spool holding an image migrates instead of uploading it"
rm -rf "$TMP/base6" "$TMP/remote6"
LEG="20200102-030405-0123456789"
mkdir -p "$TMP/base6/spool/$TODAY"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base6/spool/$TODAY/$LEG.png"
printf -- '---\ntype: capture\n---\n\nlegacy pair\n' > "$TMP/base6/spool/$TODAY/$LEG.md"
if env GARIME_CAPTURE_HOME="$TMP/base6" GARIME_REMOTE_ROOT="$TMP/remote6" \
  "$BIN" upload-once >"$TMP/upload8.log" 2>&1; then ok "upload-once drained the legacy spool"; else fail "legacy drain failed: $(cat "$TMP/upload8.log")"; fi

[ -f "$TMP/base6/archive/$TODAY/$LEG.png" ] && ok "legacy image adopted into the archive" || fail "legacy image not archived"
[ ! -e "$TMP/base6/spool/$TODAY/$LEG.png" ] && ok "legacy image left the spool" || fail "legacy image still in the spool"
[ -f "$TMP/remote6/$TODAY/$LEG.md" ] && ok "legacy markdown published" || fail "legacy markdown not published"
[ ! -e "$TMP/remote6/$TODAY/$LEG.png" ] && ok "legacy image never uploaded" || fail "legacy image was uploaded to the remote"
grep -q 'adopted legacy spool image' "$TMP/upload8.log" && ok "migration logged, not silent" || fail "legacy migration was silent"

mkdir -p "$TMP/base6/spool/$TODAY"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base6/spool/$TODAY/$LEG.png"
env GARIME_CAPTURE_HOME="$TMP/base6" GARIME_REMOTE_ROOT="$TMP/remote6" \
  "$BIN" upload-once >"$TMP/upload9.log" 2>&1
[ -f "$TMP/base6/archive/$TODAY/$LEG.png" ] && ok "already-archived image survives a re-seed" || fail "archive copy clobbered"
[ ! -e "$TMP/base6/spool/$TODAY/$LEG.png" ] && ok "duplicate spool copy dropped" || fail "duplicate left in the spool"
grep -q 'dropped the duplicate spool copy' "$TMP/upload9.log" && ok "duplicate drop logged" || fail "duplicate dropped silently"

section "T18 the archive is purged at 30 days, not before"
rm -rf "$TMP/base7" "$TMP/outside7"
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
  printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base7/archive/$d/$LEG.png"
done
mkdir -p "$TMP/base7/archive/not-a-day"
printf 'foreign' > "$TMP/base7/archive/not-a-day/marker"
ln -s "$TMP/outside7" "$TMP/base7/archive/$D60"

if env GARIME_CAPTURE_HOME="$TMP/base7" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention1.log" 2>&1; then
  ok "retention-once exited 0"
else
  fail "retention-once failed: $(cat "$TMP/retention1.log")"
fi
[ -d "$TMP/base7/archive/$D29" ] && ok "29 days old kept" || fail "29-day-old archive purged early"
[ -d "$TMP/base7/archive/$D30" ] && ok "30 days old kept (the cutoff day survives)" || fail "30-day-old archive purged early"
[ ! -e "$TMP/base7/archive/$D31" ] && ok "31 days old purged" || fail "31-day-old archive survived"
[ ! -e "$TMP/base7/archive/$D45" ] && ok "45 days old purged" || fail "45-day-old archive survived"
[ -f "$TMP/base7/archive/not-a-day/marker" ] && ok "malformed folder left alone" || fail "malformed folder deleted"
grep -q 'skipping foreign entry' "$TMP/retention1.log" && ok "foreign entry logged" || fail "foreign entry skipped silently"
[ -L "$TMP/base7/archive/$D60" ] && ok "symlinked day not followed" || fail "symlinked day removed"
[ -f "$TMP/outside7/keepme.png" ] && ok "nothing outside the archive was touched" || fail "purge escaped the archive through a symlink"

RET_FILE="$TMP/base7/status/retention.status"
[ -f "$RET_FILE" ] && ok "retention.status written" || fail "no retention.status"
grep -q '^purged_days_total=2$' "$RET_FILE" && ok "purged day counter exported (2)" || fail "purged days wrong: $(grep '^purged_days_total=' "$RET_FILE")"
grep -q '^purged_files_total=2$' "$RET_FILE" && ok "purged file counter exported (2)" || fail "purged files wrong: $(grep '^purged_files_total=' "$RET_FILE")"
grep -q '^pending_md=0$' "$RET_FILE" && ok "pending markdown reported separately from the archive" || fail "pending_md wrong: $(grep '^pending_md=' "$RET_FILE")"
grep -q '^pending_images=0$' "$RET_FILE" && ok "no image stuck in the spool" || fail "pending_images wrong: $(grep '^pending_images=' "$RET_FILE")"

env GARIME_CAPTURE_HOME="$TMP/base7" GARIME_NOW="$NOON" "$BIN" retention-once >/dev/null 2>&1
grep -q '^purged_days_total=2$' "$RET_FILE" && ok "a second pass purges nothing new" || fail "counter moved on an idempotent pass"
[ -d "$TMP/base7/archive/$D30" ] && ok "restart-safe: the 30-day folder still stands" || fail "second pass ate the cutoff day"

section "T19 retention runs offline and never waits on the uploader"
rm -rf "$TMP/base8" "$TMP/remote8"
mkdir -p "$TMP/base8/archive/$D45"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base8/archive/$D45/$LEG.png"
make_shot 'offline-case.png'
env GARIME_CAPTURE_HOME="$TMP/base8" GARIME_REMOTE_ROOT="$TMP/remote8" \
  "$BIN" spool-add "$TMP/shots/offline-case.png" >/dev/null 2>&1
env GARIME_CAPTURE_HOME="$TMP/base8" GARIME_REMOTE_ROOT="$TMP/remote8" GARIME_FAKE_EXIT=255 \
  "$BIN" upload-once >"$TMP/upload10.log" 2>&1
[ "$?" -ne 0 ] || fail "upload was supposed to fail"
env GARIME_CAPTURE_HOME="$TMP/base8" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention2.log" 2>&1 \
  && ok "retention-once succeeded with the remote down" || fail "retention needs the remote"
[ ! -e "$TMP/base8/archive/$D45" ] && ok "old archive purged while offline" || fail "purge blocked by a failed upload"
[ "$(find "$TMP/base8/spool" -type f -name '*.md' | wc -l | tr -d ' ')" = "1" ] \
  && ok "the pending markdown is still queued" || fail "retention touched the pending markdown"
[ "$(find "$TMP/base8/archive/$TODAY" -type f -name '*.png' | wc -l | tr -d ' ')" = "1" ] \
  && ok "today's image kept while its markdown waits" || fail "today's image lost"
grep -q '^pending_md=1$' "$TMP/base8/status/retention.status" && ok "status distinguishes pending markdown" || fail "pending_md not reported"

section "T20 the original dies only after the archived image and the spooled markdown"
rm -rf "$TMP/base9"
mkdir -p "$TMP/base9/archive"
chmod 500 "$TMP/base9/archive"
make_shot 'ordering-case.png'
env GARIME_CAPTURE_HOME="$TMP/base9" "$BIN" spool-add "$TMP/shots/ordering-case.png" >"$TMP/order.log" 2>&1
STATUS=$?
chmod 700 "$TMP/base9/archive"
[ "$STATUS" -ne 0 ] && ok "spool-add reports the failure" || fail "spool-add masked an archive failure"
[ -f "$TMP/shots/ordering-case.png" ] && ok "original kept when the archive write fails" || fail "original deleted without a durable archive copy"
[ "$(find "$TMP/base9/spool" -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "no orphan markdown queued for upload" || fail "markdown spooled without its archived image"
env GARIME_CAPTURE_HOME="$TMP/base9" "$BIN" spool-add "$TMP/shots/ordering-case.png" >/dev/null 2>&1 \
  && ok "the retry succeeds once the archive is writable" || fail "retry failed"
[ ! -e "$TMP/shots/ordering-case.png" ] && ok "original consumed on the successful retry" || fail "original kept after success"

section "T21 images already on the VM are never touched"
rm -rf "$TMP/base11" "$TMP/remote11"
mkdir -p "$TMP/remote11/$D45"
printf 'already-on-the-vm' > "$TMP/remote11/$D45/legacy-vm-image.png"
VM_SUM_BEFORE="$(shasum "$TMP/remote11/$D45/legacy-vm-image.png" | awk '{print $1}')"
make_shot 'vm-case.png'
env GARIME_CAPTURE_HOME="$TMP/base11" GARIME_REMOTE_ROOT="$TMP/remote11" \
  "$BIN" spool-add "$TMP/shots/vm-case.png" >/dev/null 2>&1
env GARIME_CAPTURE_HOME="$TMP/base11" GARIME_REMOTE_ROOT="$TMP/remote11" \
  "$BIN" upload-once >/dev/null 2>&1
env GARIME_CAPTURE_HOME="$TMP/base11" GARIME_NOW="$NOON" "$BIN" retention-once >/dev/null 2>&1
[ -f "$TMP/remote11/$D45/legacy-vm-image.png" ] && ok "the pre-existing VM image is still there" || fail "an image on the VM was deleted"
[ "$(shasum "$TMP/remote11/$D45/legacy-vm-image.png" | awk '{print $1}')" = "$VM_SUM_BEFORE" ] \
  && ok "its bytes are unchanged" || fail "the VM image was rewritten"

section "T22 a 45-day-old backlog image is archived under today, not born expired"
rm -rf "$TMP/base12"
make_shot 'backlog-old.png'
SetFile -d "$(date -v-45d +'%m/%d/%Y %H:%M:%S')" "$TMP/shots/backlog-old.png"
touch -t "$(date -v-45d +%Y%m%d%H%M.%S)" "$TMP/shots/backlog-old.png"
env GARIME_CAPTURE_HOME="$TMP/base12" "$BIN" spool-add "$TMP/shots/backlog-old.png" >"$TMP/backlog-add.log" 2>&1 \
  && ok "spool-add ingested the old backlog image" || fail "spool-add failed: $(cat "$TMP/backlog-add.log")"
[ "$(find "$TMP/base12/archive/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "archived under today (the retention clock starts at archiving)" || fail "backlog image not archived under $TODAY"
[ ! -d "$TMP/base12/archive/$D45" ] && ok "no archive day 45 days in the past was created" || fail "image archived into an already-expired day"
[ "$(find "$TMP/base12/spool/$D45" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the markdown still spools under its capture day" || fail "markdown not spooled under $D45"
BACK_MD="$(find "$TMP/base12/spool" -type f -name '*.md' | head -1)"
grep -q "^archived: \"$TODAY\"$" "$BACK_MD" && ok "the markdown records the archive day" || fail "markdown does not record the archive day"
env GARIME_CAPTURE_HOME="$TMP/base12" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention3.log" 2>&1 \
  && ok "retention-once exited 0" || fail "retention-once failed: $(cat "$TMP/retention3.log")"
[ "$(find "$TMP/base12/archive/$TODAY" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the backlog image survives the reaper" || fail "the backlog image was purged seconds after ingest"

section "T23 a legacy spool image is adopted into today's archive, not into an expired day"
rm -rf "$TMP/base13" "$TMP/remote13"
mkdir -p "$TMP/base13/spool/$D45"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base13/spool/$D45/$LEG.png"
printf -- '---\ntype: capture\n---\n\nlegacy backlog pair\n' > "$TMP/base13/spool/$D45/$LEG.md"
env GARIME_CAPTURE_HOME="$TMP/base13" GARIME_REMOTE_ROOT="$TMP/remote13" \
  "$BIN" upload-once >"$TMP/upload11.log" 2>&1 && ok "upload-once drained the legacy backlog spool" || fail "legacy backlog drain failed: $(cat "$TMP/upload11.log")"
[ -f "$TMP/base13/archive/$TODAY/$LEG.png" ] && ok "legacy image adopted into archive/$TODAY" || fail "legacy image not adopted into today"
[ ! -e "$TMP/base13/archive/$D45/$LEG.png" ] && ok "not adopted into the expired capture day" || fail "legacy image adopted into an expired day"
env GARIME_CAPTURE_HOME="$TMP/base13" GARIME_NOW="$NOON" "$BIN" retention-once >/dev/null 2>&1
[ -f "$TMP/base13/archive/$TODAY/$LEG.png" ] && ok "the adopted image survives the reaper" || fail "the adopted image was purged immediately"

section "T24 a condemned day loses only the artifacts this daemon generated"
rm -rf "$TMP/base14" "$TMP/outside14"
LEG2="20200102-030406-0123456789"
mkdir -p "$TMP/base14/archive/$D45/nested" "$TMP/outside14"
printf 'precious' > "$TMP/outside14/keepme.png"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base14/archive/$D45/$LEG.png"
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
[ -d "$TMP/base14/archive/$D45" ] && ok "the day dir survives while it still holds foreign content" || fail "the day dir was removed with user files inside"
RET14="$TMP/base14/status/retention.status"
grep -q '^purged_files_total=1$' "$RET14" && ok "only the deleted file is counted (1)" || fail "purged files wrong: $(grep '^purged_files_total=' "$RET14")"
grep -q '^purged_days_total=0$' "$RET14" && ok "a kept day is not counted as purged" || fail "purged days wrong: $(grep '^purged_days_total=' "$RET14")"
grep -q '^archive_files=1$' "$RET14" && ok "archive_files counts regular files only (the dir and the symlink are not files)" || fail "archive_files wrong: $(grep '^archive_files=' "$RET14")"

section "T25 a non-conforming spool file is surfaced instead of reported green"
rm -rf "$TMP/base15"
mkdir -p "$TMP/base15/spool/$TODAY" "$TMP/base15/status"
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/base15/spool/$TODAY/IMG_4021.PNG"
env GARIME_CAPTURE_HOME="$TMP/base15" GARIME_NOW="$NOON" "$BIN" retention-once >"$TMP/retention5.log" 2>&1 \
  && ok "retention-once exited 0" || fail "retention-once failed: $(cat "$TMP/retention5.log")"
grep -q '^pending_images=1$' "$TMP/base15/status/retention.status" \
  && ok "the stuck non-conforming file is reported as pending" || fail "pending_images wrong: $(grep '^pending_images=' "$TMP/base15/status/retention.status")"
grep -q '^pending_md=0$' "$TMP/base15/status/retention.status" \
  && ok "it is not miscounted as pending markdown" || fail "pending_md wrong: $(grep '^pending_md=' "$TMP/base15/status/retention.status")"
date +%s > "$TMP/base15/status/capture.heartbeat"
date +%s > "$TMP/base15/status/upload.heartbeat"
env GARIME_CAPTURE_HOME="$TMP/base15" GARIME_WATCHDOG_LOG="$TMP/watchdog3.log" GARIME_WATCHDOG_SKIP_LAUNCHCTL=1 \
  GARIME_WATCH_DIR="$TMP/base15" sh "$ROOT/garimecapture-watchdog.sh" >/dev/null 2>&1
[ $? -eq 2 ] && ok "watchdog exits 2 on a stuck spool file" || fail "watchdog stayed green on a stuck spool file"
grep -q 'stuck in the spool' "$TMP/watchdog3.log" && ok "watchdog logged the stuck file" || fail "watchdog silent about the stuck file"

section "T15 live remote smoke"
if [ "${GARIME_TEST_LIVE:-0}" != "1" ]; then
  echo "  skip: set GARIME_TEST_LIVE=1 to exercise real ssh/scp against \$GARIME_TEST_LIVE_HOST"
else
  LIVE_HOST="${GARIME_TEST_LIVE_HOST:-garime}"
  LIVE_ROOT="/tmp/garime-livesmoke-$$"
  rm -rf "$TMP/base4"; mkdir -p "$TMP/base4"
  make_shot 'live-case.png'
  env GARIME_CAPTURE_HOME="$TMP/base4" GARIME_REMOTE_HOST="$LIVE_HOST" GARIME_REMOTE_ROOT="$LIVE_ROOT" \
      GARIME_SSH_BIN=/usr/bin/ssh GARIME_SCP_BIN=/usr/bin/scp GARIME_SSH_KEY="$HOME/.ssh/garime" \
      "$BIN" spool-add "$TMP/shots/live-case.png" >/dev/null 2>&1
  env GARIME_CAPTURE_HOME="$TMP/base4" GARIME_REMOTE_HOST="$LIVE_HOST" GARIME_REMOTE_ROOT="$LIVE_ROOT" \
      GARIME_SSH_BIN=/usr/bin/ssh GARIME_SCP_BIN=/usr/bin/scp GARIME_SSH_KEY="$HOME/.ssh/garime" \
      "$BIN" upload-once >"$TMP/live.log" 2>&1
  LIVE_STATUS=$?
  [ "$LIVE_STATUS" -eq 0 ] && ok "real scp/ssh drained the spool against $LIVE_HOST" || fail "live upload failed: $(tail -3 "$TMP/live.log")"
  LIVE_COUNT="$(/usr/bin/ssh -o BatchMode=yes "$LIVE_HOST" "find '$LIVE_ROOT' -maxdepth 2 -type f | wc -l" 2>/dev/null | tr -d ' ')"
  [ "$LIVE_COUNT" = "1" ] && ok "1 markdown landed on $LIVE_HOST:$LIVE_ROOT" || fail "expected 1 remote file, got ${LIVE_COUNT:-none}"
  LIVE_IMAGES="$(/usr/bin/ssh -o BatchMode=yes "$LIVE_HOST" "find '$LIVE_ROOT' -maxdepth 2 -type f ! -name '*.md' | wc -l" 2>/dev/null | tr -d ' ')"
  [ "$LIVE_IMAGES" = "0" ] && ok "no image reached the live host" || fail "$LIVE_IMAGES image(s) on the live host"
  LIVE_LEFT="$(find "$TMP/base4/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$LIVE_LEFT" = "0" ] && ok "spool pruned after the live publish" || fail "live spool still holds $LIVE_LEFT file(s)"
  [ "$(find "$TMP/base4/archive" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
    && ok "live image kept in the local archive" || fail "live image not archived"
  /usr/bin/ssh -o BatchMode=yes "$LIVE_HOST" "rm -rf '$LIVE_ROOT'" >/dev/null 2>&1
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL GREEN"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
