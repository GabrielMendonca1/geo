# Geo

Native macOS productivity app built with Swift/SwiftUI.

## Repository Root

This repository root is canonical: `/Users/biel/ARCA/Forge/Geo`.

## Build

```bash
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' test
```

## Local Dev Checks

```bash
./scripts/dev/build.sh
./scripts/dev/test.sh
./scripts/dev/check.sh
```

## Distribution

```bash
./scripts/build_dist.sh
```
