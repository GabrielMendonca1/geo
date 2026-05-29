# Auto-update (Sparkle)

Geo ships in-app updates via [Sparkle 2.x](https://sparkle-project.org), added as an SPM
dependency and wired through `SPUStandardUpdaterController` in `GeoApp`. The
"Check for Updates…" item lives under the app menu (right below "About Geo"); Sparkle
also auto-checks on its default schedule.

Because the app is non-sandboxed (`com.apple.security.app-sandbox = false`), Sparkle runs
in-process — the Info.plist sets `SUEnableInstallerLauncherService` and
`SUEnableDownloaderService` to `false`, so no XPC services are required.

## Configuration (Info.plist)

`Geo/App/Info.plist` carries the Sparkle keys:

- `SUFeedURL` — `https://github.com/GabrielMendonca1/geo/releases/latest/download/appcast.xml`
- `SUPublicEDKey` — `__SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER__` (replace, see below)

The project now builds with `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE` pointing
at this file, so it is the live Info.plist. Both `Geo.xcodeproj` (repo root, used by
`xcodebuild`/dev) and `Geo/Geo.xcodeproj` (used by `scripts/build_dist.sh`) are wired the
same way.

## One-time setup (human-gated)

1. **Generate the EdDSA keypair.** From the Sparkle distribution run `./bin/generate_keys`
   once. It stores the private key in the login Keychain (never commit it; losing it means
   no future build can be verified) and prints the public key.
2. **Publish the public key.** Paste the printed public key into `Geo/App/Info.plist`
   under `SUPublicEDKey`, replacing `__SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER__`.
3. **Pick the feed hosting.** The default `SUFeedURL` resolves only if `appcast.xml` is
   attached as an asset to the GitHub Release marked `latest`. A more robust alternative is
   a stable gh-pages raw URL; if you switch, update `SUFeedURL` in Info.plist and `<link>`
   in `scripts/appcast.xml` to match.

The Sparkle CLI tools (`generate_keys`, `generate_appcast`, `sign_update`) live in the
Sparkle SPM artifact under
`~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`,
or download the Sparkle release tarball and use its `bin/`.

## Per-release publishing (human-gated)

1. Bump the version in `Geo/App/Info.plist`:
   - `CFBundleVersion` — a monotonically increasing **integer**. Sparkle compares this to
     decide if a build is newer; if you forget to bump it, users are never offered the
     update.
   - `CFBundleShortVersionString` — the human-facing version (e.g. `1.0.1`).
2. Build the DMG: `bash Geo/scripts/build_dist.sh` (produces `build/Geo.dmg`).
3. Put `Geo.dmg` in an updates folder and run `./bin/generate_appcast /path/to/updates/`.
   It needs Keychain access to the private key, signs the DMG, and emits `appcast.xml`
   (the `sparkle:edSignature` and `length` are filled in automatically). The
   `sparkle:version` enclosure attribute must equal `CFBundleVersion`. `generate_appcast`
   can also emit `*.delta` files for incremental updates and folds in a same-named
   `.html`/`.md` file as release notes.
4. Create the GitHub Release and upload both assets so `SUFeedURL` resolves:
   `gh release create vX.Y.Z build/Geo.dmg /path/to/updates/appcast.xml`.

`scripts/appcast.xml` is a checked-in template showing the expected shape;
`generate_appcast` regenerates it for real.

## Production signing / notarization (human-gated)

Sparkle's EdDSA-signed updates install even under ad-hoc code signing, but distributing to
other machines requires a Developer ID Application certificate plus notarization. That path
is owned by `build_dist.sh` (Developer ID, hardened runtime, inside-out signing of the
embedded `Sparkle.framework` and its nested XPC services/Autoupdate/Updater.app — no
`--deep`) followed by `xcrun notarytool submit` and `xcrun stapler staple`. See
`scripts/notarize.sh`.
