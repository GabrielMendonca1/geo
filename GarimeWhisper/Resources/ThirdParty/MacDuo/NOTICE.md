# Mac Duo — third-party notice

The `GarimeWhisper/Sources/MacDuo/` module is a derivative work of **Mac Duo**
(<https://github.com/DhananjayBhosale/MacDuo>, version 0.1.6), distributed under
the MIT License. The original license text is preserved verbatim in `LICENSE`
and the upstream attribution notes in `ATTRIBUTION.md`. The same license text is
also embedded in the binary through `MacDuoAttribution.license`.

Copyright (c) 2026 Mac Duo contributors.

## What was reused

| Upstream | Here |
|---|---|
| `Sources/FoldCore/FoldEffect.swift` | `MacDuoFoldCore.swift` (`MacDuoEffect`) |
| `Sources/FoldCore/FoldMath.swift` | `MacDuoFoldCore.swift` (`MacDuoMath`, `MacDuoAnimation`, `MacDuoFramePacing`) |
| `Sources/FoldCore/LidStillness.swift` | `MacDuoFoldCore.swift` (`MacDuoStillness`) |
| `Sources/MacDuo/LidSensor.swift` | `MacDuoLidSensor.swift` |
| `Sources/MacDuo/DesktopCapture.swift` | `MacDuoCapture.swift` |
| `Sources/MacDuo/Shader.swift` | `MacDuoShader.swift` (MSL kept byte-for-byte in behaviour) |
| `Sources/MacDuo/Renderer.swift` | `MacDuoRenderer.swift` |
| `Sources/MacDuo/AppModel.swift` | `MacDuoModel.swift` |
| `Sources/MacDuo/Controls.swift` | `MacDuoSettingsView.swift` |
| `Sources/MacDuo/main.swift` (app shell) | `MacDuoController.swift` (facade, no `@main`) |
| — (new here) | `MacDuoPolicy.swift` (pure host-integration policies) |
| `Tests/FoldCoreTests/*` | `GarimeWhisper/Tests/MacDuo/main.swift` |

## What changed

- Every upstream type was renamed with a `MacDuo` prefix: GarimeWhisper builds a
  single Swift module (`build.sh` feeds every `Sources/**/*.swift` to `swiftc`),
  so upstream names such as `AppDelegate`, `AppModel`, `AppError` or `Controls`
  would collide with existing app types.
- No `@main` / no top-level entry point. The module is driven by the facade
  `MacDuoController` (`init()`, `start()`, `showSettings()`, `stop()`).
- `start()` is inert: it only installs workspace notification observers. The HID
  lid sensor and the 10 Hz timer start on demand (settings window open, effect
  enabled, desktop test or a pending permission/sensor wait) and stop again as
  soon as all of those are false — see `MacDuoActivity`. Screen recording (TCC)
  is requested exclusively when the user presses "Enable" in the settings window,
  so nothing prompts at app launch.
- No global hot key. Upstream registered a Carbon hot key (⌃⌥⌘F plus Esc) on
  `GetApplicationEventTarget()`, which collides with the dictation hot key of the
  host app (same target, same `kEventHotKeyPressed`). Here the escape routes are:
  a click anywhere on the effect (the overlay panel takes mouse events), Esc
  while the overlay is on screen (`NSEvent` local monitor, installed only for the
  lifetime of the overlay) and the "Pause Mac Duo" button in the settings window,
  which is raised above the overlay while it is the key window.
- `checkOverlay(output:)` keeps the upstream synthetic-check guard: while it runs
  no `SCStream` is ever started, and the JSON report is written at the end of the
  run with the values actually observed.
- `UserDefaults` keys are namespaced (`macduo.*`) to avoid clashes with the host
  app defaults.
- Source comments were removed because `GarimeWhisper/smoke.sh` enforces
  comment-free Swift sources; the explanatory upstream comments live in
  `ATTRIBUTION.md`, this file, and in the upstream repository.
- The upstream `RenderCheck.swift` suite was reimplemented as the offscreen GPU
  harness in `GarimeWhisper/Tests/MacDuo/main.swift`.

## Upstream attribution chain

Mac Duo's lid reader credits [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)
(Apache License 2.0) for documenting the HID identifiers (usage page `0x20`,
usage `0x8A`, feature report id 1, two-byte little-endian degrees). No code or
asset from that project is bundled here.
