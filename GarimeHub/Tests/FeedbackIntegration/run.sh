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
  "$ROOT/Sources/Sessions/CallController.swift" \
  "$ROOT/Sources/System/PathWatcher.swift" \
  "$ROOT/Tests/FeedbackIntegration/main.swift"

"$TMP/feedback-integration"

grep -q 'SoundFeedback.shared.beginCapture(captureReason)' "$ROOT/Sources/Audio/Recorder.swift"
grep -q 'SoundFeedback.shared.endCapture(captureReason)' "$ROOT/Sources/Audio/Recorder.swift"
grep -q 'deinit {' "$ROOT/Sources/Audio/Recorder.swift"
grep -A4 'guard let engine, let url else {' "$ROOT/Sources/Audio/Recorder.swift" | grep -q 'releaseFeedbackCapture()'
grep -q 'preflightFeedback: (() -> Bool)?' "$ROOT/Sources/Sessions/MeetingController.swift"
grep -q 'meeting.preflightFeedback.*call.preflightFeedback()' "$ROOT/Sources/App/AppDelegate.swift"
grep -q 'let probe = RecProbe.read(path: Config.recStatePath)' "$ROOT/Sources/Sessions/CallController.swift"
grep -q 'reportedNothing' "$ROOT/Sources/Sessions/CallController.swift"
grep -q 'sectorChanged: { \[weak self\] in self?.playFeedback(.sectorChanged) }' "$ROOT/Sources/App/AppDelegate.swift"
grep -q 'selection: { \[weak self\] in self?.playFeedback(.selection) }' "$ROOT/Sources/App/AppDelegate.swift"
grep -q 'Self.playSectorChangedFeedback?()' "$ROOT/Sources/FileTools/UI/FloatingRadialView.swift"
grep -q 'Self.playSelectionFeedback?()' "$ROOT/Sources/FileTools/UI/FloatingRadialView.swift"
for source in \
  "$ROOT/Sources/App/AppDelegate.swift" \
  "$ROOT/Sources/Audio/Recorder.swift" \
  "$ROOT/Sources/Sessions/CallController.swift" \
  "$ROOT/Sources/System/PathWatcher.swift" \
  "$ROOT/Sources/Sessions/MeetingController.swift" \
  "$ROOT/Sources/FileTools/UI/FloatingRadialView.swift"; do
  ! grep -Eq '(^|[^:])//|/\*' "$source"
done
echo "feedback wiring checks passed"
