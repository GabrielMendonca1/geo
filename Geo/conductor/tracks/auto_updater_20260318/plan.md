# Track: Git-Based Auto-Updater

**Status:** Future
**Created:** 2026-03-18
**Goal:** Ship a self-updating mechanism for Geo using GitHub Releases as the distribution backend.

---

## Overview

The app checks GitHub Releases API for new versions, downloads the DMG, verifies integrity, replaces itself, and relaunches. The GitHub side uses Actions to build, sign, notarize, and publish releases on tag push.

---

## Prerequisites

- [ ] Change bundle ID from `com.example.mac.Geo` to production identifier
- [ ] Apple Developer account with Developer ID Application certificate
- [ ] Decide: public or private repo (affects API auth requirements)
- [ ] Decide: Sparkle vs custom (custom = full control + learning, Sparkle = battle-tested in 2 hours)

---

## Phase 1 — GitHub Release Pipeline

### 1.1 GitHub Actions Workflow

**File:** `.github/workflows/release.yml`
**Trigger:** Tag push matching `v*.*.*`

Steps:
1. Checkout code
2. Install Apple certificate from GitHub Secrets into temporary keychain
3. `xcodebuild archive` with Developer ID signing
4. Export `.app` with `exportOptionsPlist` (method: `developer-id`)
5. Notarize with `notarytool submit` + `stapler staple`
6. **Clear old DMG artifacts** (`rm -rf build/`)
7. **Generate fresh DMG** via `scripts/build_dist.sh` (or inline `create-dmg`)
8. Compute SHA256 of DMG
9. Generate `release-manifest.json`
10. Create GitHub Release with DMG + manifest attached via `gh release create`

### 1.2 GitHub Secrets

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE_P12` | Developer ID Application certificate (base64) |
| `APPLE_CERTIFICATE_PASSWORD` | Certificate password |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_TEAM_ID` | Team identifier |
| `APPLE_APP_PASSWORD` | App-specific password for notarytool |
| `SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |

### 1.3 Release Manifest

Each release gets a `release-manifest.json` asset:

```json
{
  "version": "2.1.0",
  "build": 3,
  "minimumSystemVersion": "14.0",
  "dmgURL": "https://github.com/{owner}/Geo/releases/download/v2.1.0/Geo.dmg",
  "sha256": "...",
  "releaseNotes": "...",
  "date": "2026-03-18T00:00:00Z"
}
```

Alternative: skip manifest, parse GitHub Releases API directly (it has tag, assets, body).

### 1.4 Update `build_dist.sh`

Current script already cleans `build/` and removes old DMG before generating. Enhancements needed:

- Accept `--version` flag to stamp `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` at build time
- Accept `--sign-identity` flag to replace ad-hoc signing with real identity
- Add `--notarize` flag to submit + staple after DMG creation
- Output SHA256 checksum to `build/Geo.dmg.sha256`
- Generate `release-manifest.json` into `build/`

Flow:
```
build_dist.sh --version 2.1.0 --sign-identity "Developer ID Application: ..." --notarize
  → rm -rf build/
  → xcodebuild archive (with version stamped)
  → export .app
  → codesign with real identity
  → notarytool submit + stapler staple
  → rm -f build/Geo.dmg  (clear old DMG)
  → create-dmg → build/Geo.dmg  (generate new DMG)
  → sha256sum → build/Geo.dmg.sha256
  → generate build/release-manifest.json
```

---

## Phase 2 — App: Core Update Logic

### 2.1 File Structure

```
Features/
  Update/
    Data/
      GitHubReleaseFetcher.swift
    Domain/
      UpdateService.swift
      UpdateInstaller.swift
      UpdateState.swift
      SemanticVersion.swift
    UI/
      UpdateSettingsView.swift
      UpdateAlertView.swift
      UpdateProgressView.swift
```

### 2.2 `SemanticVersion`

- Parse version strings: `"2.1.0"` → `(major: 2, minor: 1, patch: 0)`
- Comparable conformance
- Handle tag prefix stripping: `"v2.1.0"` → `"2.1.0"`

### 2.3 `GitHubReleaseFetcher`

- `GET https://api.github.com/repos/{owner}/Geo/releases/latest`
- Parse: tag name, asset download URLs, release body (notes), published date
- URLSession only, no dependencies
- For private repo: optional Bearer token from UserDefaults or Keychain
- Rate limit awareness (60 req/hr unauthenticated, 5000 authenticated)

### 2.4 `UpdateService`

- On launch: background check after 5s delay
- Periodic: re-check every 24h (configurable)
- Manual: "Check for Updates" triggers immediate check
- Compare `Bundle.version` vs latest release tag via `SemanticVersion`
- UserDefaults keys: `lastUpdateCheck`, `skippedVersion`, `autoCheckEnabled`, `checkInterval`
- Publishes `UpdateState` for UI binding

### 2.5 `UpdateState`

```swift
enum UpdateStatus {
    case idle
    case checking
    case available(GitHubRelease)
    case downloading(progress: Double)
    case readyToInstall(localURL: URL)
    case installing
    case failed(Error)
}

struct GitHubRelease {
    let version: SemanticVersion
    let dmgURL: URL
    let sha256: String?
    let releaseNotes: String
    let publishedDate: Date
}
```

---

## Phase 3 — App: Download & Install

### 3.1 Download Manager

- URLSession download task to `~/Library/Application Support/Geo/Updates/`
- Progress tracking via URLSessionDownloadDelegate
- SHA256 verification against manifest
- Clean up old downloads before starting new one

### 3.2 Installation Strategy

The app cannot replace itself while running. Use a helper script:

1. Download DMG → `~/Library/Application Support/Geo/Updates/Geo.dmg`
2. Verify SHA256
3. Mount DMG, copy `.app` to staging path, unmount
4. Write `/tmp/geo-updater.sh`:
   ```bash
   #!/bin/bash
   APP_PID=$1; OLD_APP=$2; NEW_APP=$3
   while kill -0 $APP_PID 2>/dev/null; do sleep 0.5; done
   rm -rf "$OLD_APP"
   mv "$NEW_APP" "$OLD_APP"
   open "$OLD_APP"
   rm -f "$0"
   ```
5. Launch script via `Process`, call `NSApp.terminate(nil)`

**Future improvement:** Replace shell script with a Swift helper binary at `Geo.app/Contents/Helpers/GeoUpdater` for proper error handling and code signature verification.

### 3.3 Rollback

- Before replacing, copy current `.app` to `~/Library/Application Support/Geo/Updates/Geo-backup.app`
- If new version crashes within 30s of first launch, offer to restore backup
- Track launch success with a `launchSuccessful` flag written after 30s uptime

---

## Phase 4 — App: UI

### 4.1 Settings Integration

Add to Settings → Advanced pane (`GeneralSettingsView.swift`):
- "Automatically check for updates" toggle (default: on)
- Check frequency picker: every launch / daily / weekly
- "Check Now" button
- "Include pre-release versions" toggle (maps to GitHub pre-release flag)

### 4.2 About Window

Add "Check for Updates" button in `AboutView.swift` below version info.

### 4.3 Menu Bar

Add `Geo > Check for Updates...` menu item (standard macOS convention).

### 4.4 Update Alert

Sheet or standalone window:
- App icon + "A new version of Geo is available"
- Version comparison: "Geo 2.0 → 2.1.0"
- Release notes (rendered markdown)
- "Update & Restart" primary button
- "Skip This Version" / "Remind Me Later" secondary buttons
- Download progress bar when downloading

---

## Phase 5 — Hardening

- [ ] Verify code signature of downloaded `.app` via `SecStaticCode`
- [ ] Certificate pinning on GitHub API (optional, paranoid mode)
- [ ] Rollback mechanism if new version crashes on launch
- [ ] Handle edge cases: interrupted downloads, disk full, permissions errors, DMG mount failures
- [ ] Graceful degradation when offline
- [ ] Logging: log update checks and results for debugging
- [ ] Analytics: optional anonymous update success/failure tracking

---

## Decision Log

| Decision | Options | Status |
|---|---|---|
| Custom vs Sparkle | Custom (full control + learning) / Sparkle (2 hours, battle-tested) | **TBD** |
| Public vs private repo | Public (no auth) / Private (needs token) | **TBD** |
| Release artifact format | DMG (current) / ZIP (simpler extraction) / Both | **TBD** |
| Helper mechanism | Shell script (simple) / Swift binary (robust) | Shell script first, upgrade later |
| Release channels | Stable only / Stable + Beta (pre-release) | **TBD** |

---

## References

- GitHub Releases API: `https://docs.github.com/en/rest/releases`
- Apple notarization: `xcrun notarytool submit`
- Sparkle 2: `https://sparkle-project.org` (if we go that route)
- Current build script: `scripts/build_dist.sh`
- Bundle version helpers: `Extensions/Bundle+Version.swift`
