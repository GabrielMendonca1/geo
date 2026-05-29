# Auto-update (Sparkle)

Geo ships as a Developer ID-signed, notarized DMG outside the App Store, so updates run
through [Sparkle 2](https://sparkle-project.org). The app code below is ready to paste; the
three steps that need you (add the SPM dependency, generate the signing key, host the feed)
are called out explicitly.

Workflow `geo-1.0.0-finish-blockers` could not add the SPM dependency by hand-editing
`project.pbxproj` without breaking the build (Apple exposes no reliable CLI for this), so it
reverted that change. Everything below is the safe path: a ~1-minute GUI action plus the
human-gated key/hosting steps.

## 1. Add Sparkle (Xcode GUI — one time)

`File ▸ Add Package Dependencies…` → `https://github.com/sparkle-project/Sparkle` →
Dependency Rule: **Up to Next Major `2.0.0`** → Add Package → add the **Sparkle** library
product to the **Geo** app target.

`build_dist.sh` already deep-signs every embedded `.framework`/`.xpc` with the Developer ID
identity and `--options runtime --timestamp`, so Sparkle's `Autoupdate`/`Updater.app` XPC
helpers are covered at distribution time with no script change.

## 2. Wire the updater (paste-ready)

Create `Geo/App/Commands/CheckForUpdatesCommand.swift` and add it to the Geo target:

```swift
import SwiftUI
import Sparkle

final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesCommand: Commands {
    @ObservedObject var model: UpdaterViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.controller.updater.checkForUpdates() }
                .disabled(!model.canCheckForUpdates)
        }
    }
}
```

In `Geo/App/GeoApp.swift`, own the model and install the command in the `Settings`/main scene:

```swift
@StateObject private var updaterModel = UpdaterViewModel()
// …
.commands { CheckForUpdatesCommand(model: updaterModel) }
```

## 3. Info.plist keys

The project uses `GENERATE_INFOPLIST_FILE = YES` (the `Geo/App/Info.plist` on disk is **dead
code**, not referenced by the build), so add these via the **Geo target ▸ Info** tab, which
writes them into the synthesized plist:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `https://github.com/GabrielMendonca1/geo/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | *(the public key from step 4)* |
| `SUEnableInstallerLauncherService` | `YES` *(non-sandboxed installer helper)* |

## 4. Generate the signing key — HUMAN-GATED

Sparkle signs updates with an EdDSA key kept **out of the repo**:

```bash
# from the Sparkle package's artifacts (DerivedData/.../Sparkle/bin) or the release tarball
./generate_keys                 # creates the private key in your login Keychain
./generate_keys -p              # prints the PUBLIC key → paste into SUPublicEDKey (step 3)
```

The private key never leaves your machine / CI secret store. Losing it means you can no
longer ship updates that existing installs will accept — back it up (`./generate_keys -x
sparkle_private_key.pem`, store securely, then delete the file).

## 5. Build the appcast & publish — HUMAN-GATED

`appcast.xml` is **generated**, not hand-written. After `build_dist.sh` + `notarize.sh`
produce the stapled DMG:

```bash
./generate_appcast /path/to/dir-containing/Geo-1.0.0.dmg   # signs + writes appcast.xml
```

Then publish both to the GitHub release so `SUFeedURL` resolves:

```bash
gh release create v1.0.0 build/Geo.dmg build/appcast.xml --title "Geo 1.0.0" --notes "…"
# subsequent releases: regenerate appcast.xml over ALL dmgs, then
gh release upload v1.0.x build/Geo.dmg build/appcast.xml --clobber
```

Add a `generate_appcast` + `gh release upload appcast.xml` step to
`.github/workflows/release.yml` so each tagged release refreshes the feed automatically.

## Checklist

- [ ] Step 1 — Sparkle SPM dependency added to the Geo target (GUI)
- [ ] Step 2 — `CheckForUpdatesCommand.swift` added; menu builds
- [ ] Step 3 — `SUFeedURL` + `SUPublicEDKey` set on the target
- [ ] Step 4 — EdDSA keypair generated, private key backed up, public key in `SUPublicEDKey`
- [ ] Step 5 — first `gh release` carries `Geo.dmg` + `appcast.xml`; `release.yml` updated
