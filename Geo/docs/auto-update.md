# Auto-update (Sparkle)

Geo updates via [Sparkle 2](https://sparkle-project.org). **The app side is fully wired and
build-verified** — Sparkle is integrated, the menu item works, and update integrity is
verified by Sparkle's own EdDSA signature. **No Apple Developer ID / notarization is required**
for updates to work (open-source, non-App-Store). The only effect of not notarizing is a
one-time Gatekeeper prompt on first download (right-click → Open, or
`xattr -dr com.apple.quarantine /Applications/Geo.app`).

## What's already done (in the root `Geo.xcodeproj`)

- **Sparkle 2.9.2** added as an SPM dependency, linked + embedded in `Geo.app/Contents/Frameworks`.
- **"Check for Updates…"** menu item (`CheckForUpdatesCommand` in `Geo/App/GeoApp.swift`,
  wired to `SPUStandardUpdaterController`).
- **Feed config** in `Geo/App/Info.plist` (the active `INFOPLIST_FILE`, merged under the
  generated keys):
  - `SUFeedURL` = `https://github.com/GabrielMendonca1/geo/releases/latest/download/appcast.xml`
  - `SUPublicEDKey` = `56J+eMQkl/Aalsq7PW3MSlPWR+dqn+ZLtVC4StxPzoQ=`
- **EdDSA keypair generated** — public key above; **private key is in your login Keychain**.

## ⚠️ Do this now: back up the private key

If you lose it, you can never again ship an update that existing installs will accept.

```bash
# export, store somewhere safe (password manager / encrypted backup), then delete the file
DERIVED=$(ls -d ~/Library/Developer/Xcode/DerivedData/Geo-*/ | head -1)
"$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -x sparkle_private_key.pem
# move sparkle_private_key.pem to secure storage, then: rm sparkle_private_key.pem
```

## Cutting a release (no Apple cert needed)

1. Build a Release `.app` and pack it (zip or dmg). Either use the existing
   `Geo/scripts/build_dist.sh` (it does Developer-ID signing — only if you ever add a cert),
   or simply archive + export with automatic signing and zip the `.app`.
2. Sign the update + (re)generate the feed with the EdDSA key from your Keychain:
   ```bash
   "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" /path/to/dir-with/Geo-1.0.0.zip
   # writes appcast.xml (signed) into that directory
   ```
3. Publish the binary **and** `appcast.xml` to the GitHub release so `SUFeedURL` resolves:
   ```bash
   gh release create v1.0.0 build/Geo-1.0.0.zip build/appcast.xml --title "Geo 1.0.0" --notes "…"
   # later releases: regenerate appcast.xml over ALL archives, then
   gh release upload v1.0.x build/Geo-1.0.x.zip build/appcast.xml --clobber
   ```

Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) per release so Sparkle sees the new
version as newer.

## Optional: notarization (smoother first-run)

`Geo/scripts/build_dist.sh` + `notarize.sh` + `.github/workflows/release.yml` are written for
Developer-ID signing + notarization, which would remove the Gatekeeper prompt. They stay
dormant until you set the Apple credentials (`TEAM_ID`, `DEVELOPER_ID_APP`, `NOTARY_PROFILE`).
Not required for auto-update.
