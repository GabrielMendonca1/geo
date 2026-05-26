#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' build
