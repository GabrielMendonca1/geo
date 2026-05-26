# AGENTS.md

## Scope

- Primary project file: `Geo.xcodeproj`

## Structure

- `App/` app entry, composition, Notch UI
- `Features/` feature-first domains (each owns `Data/`, `Domain/`, `UI/`)
- `Shared/` cross-cutting infrastructure, design system, platform, support
- `Utilities/`, `Extensions/` small cross-cutting helpers
- `Tests/` XCTest target
- `conductor/` product/process tracks
- `docs/` ADRs and architecture notes
- `scripts/` build, dev, dist

## Required Commands

- Build: `xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' build`
- Test: `xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' test`
- Distribution: `./scripts/build_dist.sh`

## Guardrails

- One domain per PR (no mixed structural + feature + asset refactors).
- New generated artifacts must never be tracked (`build/`, `build-iso*/`, `.DS_Store`, `xcuserdata`, `*.profraw`).
- Prefer small vertical slices; avoid massive move-only changes.
- Any file change >250 lines should be split or justified in PR notes.

## Architecture Rules

- Views must not directly access `FileManager`, `UserDefaults`, or GRDB APIs.
- Persistence must flow through repositories/use-cases.
- New code lands in `Features/*` and `Shared/*`.

## PR Change Log Template

Include these sections in every PR:

1. What changed
2. Why
3. How tested
4. Fallback
