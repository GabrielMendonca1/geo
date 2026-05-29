# Installing Geo 1.0.0

Geo is a native macOS productivity hub (Swift/SwiftUI, local-first) plus the **hermes** LaunchAgent that reads and writes Geo's data over MCP.

> **Heads up:** this build is **unsigned** (ad-hoc). It is **not** notarized, has **no Developer ID signature**, and there is **no auto-updater** — updates are manual rebuilds. macOS Gatekeeper will flag it as coming from an "unidentified developer"; see [Gatekeeper](#gatekeeper-unidentified-developer) below.

## Requirements

- macOS with Xcode + command-line tools installed.

## Build from source

From the repo root (`/Users/biel/ARC/Forge/Geo`):

```bash
# Build the app
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' build

# Run the tests
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' test

# Clean
xcodebuild clean -scheme Geo
```

The built `Geo.app` is emitted under the Xcode `DerivedData` build products directory. Copy it into `/Applications` (or wherever you keep apps) and launch from there.

## Install the hermes daemon

hermes is the 24/7 agent LaunchAgent (`ai.hermes.gateway`) that keeps WhatsApp / Gmail / Telegram online, runs cron prompts, and serves the in-app Nano pane over HTTP+SSE on `127.0.0.1:8642`.

```bash
bash hermes/install.sh             # drops the plist into ~/Library/LaunchAgents and starts the gateway
launchctl list ai.hermes.gateway   # verify it is running
```

Runtime state lives in `~/.hermes/` (`.env` for API keys/connector creds, `SOUL.md`, `memories/`, `db/hermes.sqlite`, `logs/gateway.log`) — managed by hermes, not checked into this repo.

## Gatekeeper ("unidentified developer")

Because the build is unsigned, double-clicking `Geo.app` the first time will be blocked. To open it:

1. **Right-click** (or Control-click) `Geo.app` in Finder.
2. Choose **Open**.
3. In the dialog, click **Open** again to confirm.

macOS remembers this choice, so subsequent launches work normally.

## macOS permissions

Sandboxing is **off** by design (`com.apple.security.app-sandbox = false`) — Geo needs system-level access to do its job. Grant these in **System Settings → Privacy & Security**. macOS will prompt on first use; you may need to add Geo manually and restart the app.

| Permission | Why Geo needs it |
| --- | --- |
| **Accessibility** | The global hotkey and capture pipeline use a `CGEventTap`; macOS requires Accessibility to install one. |
| **Input Monitoring** | Same `CGEventTap` — observing the keyboard for the global hotkey requires Input Monitoring. |
| **Screen Recording** | Screenshot capture + Vision **OCR** read on-screen content, which macOS gates behind Screen Recording. |
| **Camera** | Capturing images (`NSCameraUsageDescription`). |
| **Automation / Apple Events** | Automating tasks and managing system functionality (`NSAppleEventsUsageDescription`). |

If the global hotkey or OCR silently does nothing, the usual cause is a missing Accessibility / Input Monitoring / Screen Recording grant — re-check the lists and restart Geo.

## Where your data lives

Geo is local-first. The app is the sole owner of its data on disk:

```
~/Library/Application Support/Geo/
  Blocks/*.md     markdown notes
  Tasks/*.md      tasks
  tags.json       tags
  days.json       day records
```

### Backups

There is no built-in backup. To back up manually, copy the whole folder:

```bash
cp -R ~/Library/Application\ Support/Geo ~/Desktop/Geo-backup-$(date +%Y%m%d)
```

To restore, quit Geo and copy a backup folder back into place.
