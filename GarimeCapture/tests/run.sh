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
[ "$spooled" = "10" ] && ok "5 image+md pairs spooled" || fail "expected 10 spooled files, got $spooled"

bad=0
while IFS= read -r f; do
  name="$(basename "$f")"
  echo "$name" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\.(png|md)$' || { fail "unsafe spool name: $name"; bad=1; }
done < <(find "$SPOOL/$TODAY" -type f)
[ "$bad" = "0" ] && ok "every spool name matches the safe whitelist"

section "T2 upload publishes to the remote and prunes the spool"
if "$BIN" upload-once >"$TMP/upload1.log" 2>&1; then ok "upload-once exited 0"; else fail "upload-once failed: $(cat "$TMP/upload1.log")"; fi

published="$(find "$REMOTE/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$published" = "10" ] && ok "10 files landed in $REMOTE/$TODAY" || fail "expected 10 published files, got $published"

left="$(find "$SPOOL" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok "spool pruned only after confirmed upload" || fail "spool still holds $left file(s)"

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
[ "$still" = "2" ] && ok "spool intact after failed upload" || fail "spool damaged: $still file(s)"
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
[ "$still" = "2" ] && ok "spool preserved through the stall" || fail "spool damaged by stall: $still"

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
rm -rf "$TMP/base/spool" "$TMP/remote" "$TMP/watch"
mkdir -p "$TMP/watch"
GARIME_WATCH_DIR="$TMP/watch" GARIME_UPLOAD_INTERVAL=2 "$BIN" >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 3
printf '%s' "$PNG_B64" | base64 --decode > "$TMP/watch/daemon-case.png"

for _ in $(seq 1 40); do
  published="$(find "$TMP/remote/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  pending="$(find "$TMP/base/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$published" -ge 2 ] && [ "$pending" -eq 0 ] && break
  sleep 1
done
kill "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null

delivered="$(find "$TMP/remote/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$delivered" = "2" ] && ok "daemon delivered the pair end to end" || fail "expected 2 delivered files, got $delivered"
[ ! -e "$TMP/watch/daemon-case.png" ] && ok "original consumed by the daemon" || fail "original left in the watch dir"
left="$(find "$TMP/base/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok "daemon pruned the spool after upload" || fail "spool holds $left file(s)"
[ -f "$TMP/base/status/capture.heartbeat" ] && ok "capture heartbeat written" || fail "no capture heartbeat"
[ -f "$TMP/base/status/upload.heartbeat" ] && ok "upload heartbeat written" || fail "no upload heartbeat"
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
rm -rf "$SPOOL" "$REMOTE"
make_shot 'temp-case.png'
"$BIN" spool-add "$TMP/shots/temp-case.png" >/dev/null 2>&1
IMG="$(find "$SPOOL/$TODAY" -name '*.png' | head -1)"
TEMP_NAME="$(basename "$IMG").sb-7e736f51-N6HG8B"
printf 'PARTIAL-GARBAGE' > "$SPOOL/$TODAY/$TEMP_NAME"
"$BIN" upload-once >"$TMP/upload5.log" 2>&1 && ok "upload-once exited 0 alongside a temp file" || fail "upload-once failed: $(cat "$TMP/upload5.log")"

[ -e "$REMOTE/$TODAY/$TEMP_NAME" ] && fail "atomic temp file was published into the vault" || ok "atomic temp file never reached the remote"
[ -e "$SPOOL/$TODAY/$TEMP_NAME" ] && ok "atomic temp left untouched for its writer" || fail "uploader unlinked another thread's temp file"
published="$(find "$REMOTE/$TODAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$published" = "2" ] && ok "only the real pair was published" || fail "expected 2 published files, got $published"
grep -q 'skipping foreign file' "$TMP/upload5.log" && ok "foreign spool file logged" || fail "foreign file skipped silently"
rm -rf "$SPOOL" "$REMOTE"

section "T11 spooled bytes are fsynced before the original is deleted"
grep -q 'F_FULLFSYNC' "$ROOT/Sources/Support.swift" && ok "F_FULLFSYNC used for durability" || fail "no F_FULLFSYNC in Support.swift"
grep -q 'syncToDisk(url)' "$ROOT/Sources/Spool.swift" && ok "file contents fsynced after write" || fail "spool writes are not fsynced"
grep -q 'syncToDisk(dayDir)' "$ROOT/Sources/Spool.swift" && ok "spool directory fsynced before success is reported" || fail "spool directory is not fsynced"

section "T12 a permanently failing uploader is loud, not silently green"
make_shot 'alarm-case.png'
"$BIN" spool-add "$TMP/shots/alarm-case.png" >/dev/null 2>&1
GARIME_FAKE_EXIT=255 "$BIN" upload-once >"$TMP/upload6.log" 2>&1
GARIME_FAKE_EXIT=255 "$BIN" upload-once >>"$TMP/upload6.log" 2>&1
STATUS_FILE="$TMP/base/status/upload.status"
[ -f "$STATUS_FILE" ] && ok "upload.status written" || fail "no upload.status file"
grep -q '^failures=2$' "$STATUS_FILE" && ok "consecutive failures counted (2)" || fail "failure counter wrong: $(grep '^failures=' "$STATUS_FILE")"
grep -q '^spool_files=2$' "$STATUS_FILE" && ok "spool depth exported" || fail "spool depth wrong: $(grep '^spool_files=' "$STATUS_FILE")"
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
rm -rf "$SPOOL" "$REMOTE"

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
  [ "$(find "$TMP/remote3/$BACKLOG_DAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 1
done
kill "$D3_PID" 2>/dev/null; wait "$D3_PID" 2>/dev/null
delivered="$(find "$TMP/remote3/$BACKLOG_DAY" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$delivered" = "2" ] && ok "2h-old backlog delivered end to end" || fail "expected 2 delivered files, got $delivered"
[ ! -e "$TMP/watch3/backlog.png" ] && ok "backlog original consumed" || fail "backlog original abandoned"

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
  [ "$LIVE_COUNT" = "2" ] && ok "2 files landed on $LIVE_HOST:$LIVE_ROOT" || fail "expected 2 remote files, got ${LIVE_COUNT:-none}"
  LIVE_LEFT="$(find "$TMP/base4/spool" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$LIVE_LEFT" = "0" ] && ok "spool pruned after the live publish" || fail "live spool still holds $LIVE_LEFT file(s)"
  /usr/bin/ssh -o BatchMode=yes "$LIVE_HOST" "rm -rf '$LIVE_ROOT'" >/dev/null 2>&1
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL GREEN"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
