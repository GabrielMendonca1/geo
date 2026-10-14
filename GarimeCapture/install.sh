#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="ai.garime.capture"
WATCHDOG_LABEL="ai.garime.capture-watchdog"
BIN_DIR="${GARIME_BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/garimecapture"
WATCHDOG="$BIN_DIR/garimecapture-watchdog.sh"
AGENTS="${GARIME_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LOGS="$HOME/Library/Logs/garime"
SKIP_LAUNCHCTL="${GARIME_INSTALL_SKIP_LAUNCHCTL:-0}"

STAGED_AGENTS="$(mktemp -d "${TMPDIR:-/tmp}/garimecapture-install.XXXXXX")"
trap 'rm -rf "$STAGED_AGENTS"' EXIT

unload() {
  [ "$SKIP_LAUNCHCTL" = "1" ] && return 0
  if launchctl print "gui/$UID/$1" >/dev/null 2>&1; then
    echo "install: unloading $1"
    launchctl bootout "gui/$UID/$1" 2>/dev/null || true
  fi
}

# GARIME_ARCHIVE_DIR is never defaulted here: it is written into the agent only if
# this install was asked for it, or if the installed agent already carried one.
agent_archive_dir() {
  target="$1"
  if [ -n "${GARIME_ARCHIVE_DIR:-}" ]; then
    printf '%s' "$GARIME_ARCHIVE_DIR"
    return 0
  fi
  [ -f "$target" ] || return 0
  plutil -extract EnvironmentVariables.GARIME_ARCHIVE_DIR raw -o - "$target" 2>/dev/null || true
}

agent_archive_layout() {
  if [ -n "${GARIME_ARCHIVE_LAYOUT:-}" ]; then
    printf '%s' "$GARIME_ARCHIVE_LAYOUT"
    return 0
  fi
  [ -f "$1" ] || return 0
  plutil -extract EnvironmentVariables.GARIME_ARCHIVE_LAYOUT raw -o - "$1" 2>/dev/null || true
}

write_agent() {
  label="$1"
  archive_dir="$(agent_archive_dir "$AGENTS/$label.plist")"
  archive_layout="$(agent_archive_layout "$AGENTS/$label.plist")"
  target="$STAGED_AGENTS/$label.plist"
  echo "install: preparing $AGENTS/$label.plist"
  sed -e "s#/Users/biel/.local/bin#$BIN_DIR#g" \
      -e "s#/Users/biel/Library/Logs/garime#$LOGS#g" \
      "$ROOT/$label.plist" > "$target"
  if [ "$label" = "$LABEL" ]; then
    case "$archive_layout" in
      ""|dated|flat) ;;
      *) echo "install: GARIME_ARCHIVE_LAYOUT must be dated or flat" >&2; exit 1 ;;
    esac
    if [ -n "$archive_dir$archive_layout" ]; then
      plutil -replace EnvironmentVariables -xml '<dict/>' "$target" >/dev/null
    fi
    if [ -n "$archive_layout" ]; then
      plutil -insert EnvironmentVariables.GARIME_ARCHIVE_LAYOUT -string "$archive_layout" "$target" >/dev/null
    fi
  fi
  if [ "$label" = "$LABEL" ] && [ -n "$archive_dir" ]; then
    case "$archive_dir" in
      /*) ;;
      *) echo "install: GARIME_ARCHIVE_DIR must be an absolute path (got '$archive_dir')" >&2; exit 1 ;;
    esac
    echo "install: preserving GARIME_ARCHIVE_DIR=$archive_dir in $label"
    plutil -insert EnvironmentVariables.GARIME_ARCHIVE_DIR -string "$archive_dir" "$target" >/dev/null
  fi
  plutil -lint "$target" >/dev/null
}

# Validate both plists before touching the installed files or stopping services.
write_agent "$LABEL"
write_agent "$WATCHDOG_LABEL"

"$ROOT/build.sh"

if [ ! -x "$ROOT/build/garimecapture" ]; then
  echo "install: build output missing at $ROOT/build/garimecapture" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$AGENTS" "$LOGS"
unload "$LABEL"
unload "$WATCHDOG_LABEL"

echo "install: copying binary to $BIN"
rm -f "$BIN"
cp "$ROOT/build/garimecapture" "$BIN"
chmod 755 "$BIN"

echo "install: copying watchdog to $WATCHDOG"
cp "$ROOT/garimecapture-watchdog.sh" "$WATCHDOG"
chmod 755 "$WATCHDOG"

for label in "$LABEL" "$WATCHDOG_LABEL"; do
  mv "$STAGED_AGENTS/$label.plist" "$AGENTS/$label.plist"
done

if [ "$SKIP_LAUNCHCTL" = "1" ]; then
  echo "install: GARIME_INSTALL_SKIP_LAUNCHCTL=1, not touching launchd"
  exit 0
fi

for label in "$LABEL" "$WATCHDOG_LABEL"; do
  echo "install: bootstrapping $label"
  launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist"
  launchctl kickstart "gui/$UID/$label"
done

echo "install: ok"
launchctl print "gui/$UID/$LABEL" | grep -E 'state =|program =' || true
