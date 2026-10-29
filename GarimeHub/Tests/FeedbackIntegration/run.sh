#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  -O \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -framework AppKit \
  -o "$TMP/feedback-integration" \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Sources/Feedback/FeedbackPreferences.swift" \
  "$ROOT/Sources/Feedback/FeedbackPolicy.swift" \
  "$ROOT/Sources/Feedback/FeedbackVoice.swift" \
  "$ROOT/Sources/Feedback/SoundFeedback.swift" \
  "$ROOT/Sources/Feedback/FeedbackSettings.swift" \
  "$ROOT/Tests/FeedbackIntegration/main.swift"

"$TMP/feedback-integration"

grep -q 'SoundFeedback.shared.beginCapture(captureReason)' "$ROOT/Sources/Audio/Recorder.swift"
grep -q 'SoundFeedback.shared.endCapture(captureReason)' "$ROOT/Sources/Audio/Recorder.swift"
grep -q 'deinit {' "$ROOT/Sources/Audio/Recorder.swift"
grep -A4 'guard let engine, let url else {' "$ROOT/Sources/Audio/Recorder.swift" | grep -q 'releaseFeedbackCapture()'
echo "feedback wiring checks passed"
