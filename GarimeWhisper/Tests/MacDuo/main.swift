import AppKit
import Metal
import MetalKit
import Foundation

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double, _ label: String) {
    check(abs(lhs - rhs) <= tolerance, "\(label) [got: \(lhs), want: \(rhs) ±\(tolerance)]")
}

print("== 1. effect catalog ==")
equal(MacDuoEffect.allCases.count, 5, "five effects")
equal(MacDuoEffect.allCases.map { $0.shaderIndex }, [0, 1, 2, 3, 4], "shader indices are the stable contract")
equal(MacDuoEffect.fallback, .duo, "duo is the fallback")
equal(MacDuoEffect.resolve(persisted: nil), .duo, "an unreadable selection falls back")
equal(MacDuoEffect.resolve(persisted: "nonsense"), .duo, "an unknown selection falls back")
equal(MacDuoEffect.resolve(persisted: "iris"), .iris, "a saved selection is restored")
equal(MacDuoEffect.resolve(shaderIndex: 9), .duo, "an unknown shader index falls back")
equal(MacDuoEffect.resolve(shaderIndex: 3), .flex, "a known shader index resolves")
check(Set(MacDuoEffect.allCases.map { $0.persistedIdentifier }).count == 5, "persisted identifiers are unique")
check(!MacDuoEffect.duo.needsPrefilteredSource, "duo keeps its sharp path at zero softness")
check(MacDuoEffect.allCases.filter { $0 != .duo }.allSatisfy { $0.needsPrefilteredSource }, "curved effects prefilter the source")

print("== 2. fold math ==")
equal(MacDuoMath.progress(angle: 180, clearAngle: 105), 0, "an open lid is fully clear")
equal(MacDuoMath.progress(angle: 105, clearAngle: 105), 0, "progress starts exactly at the clear angle")
equal(MacDuoMath.progress(angle: 5, clearAngle: 105), 1, "a closed lid is fully folded")
equal(MacDuoMath.progress(angle: 1, clearAngle: 105), 1, "progress never exceeds one")
equal(MacDuoMath.progress(angle: .nan, clearAngle: 105), 0, "a broken angle is clear")
near(MacDuoMath.progress(angle: 55, clearAngle: 105), 0.5, 0.001, "the midpoint is smoothstepped to a half")
check(MacDuoMath.progress(angle: 90, clearAngle: 40) == MacDuoMath.progress(angle: 90, clearAngle: 60), "the clear angle is clamped low")
check(MacDuoMath.progress(angle: 90, clearAngle: 200) == MacDuoMath.progress(angle: 90, clearAngle: 140), "the clear angle is clamped high")
check(MacDuoMath.smooth(current: 0, target: 1, dt: 0.016) > 0, "smoothing advances")
check(MacDuoMath.smooth(current: 0, target: 1, dt: 0.016) < 1, "smoothing does not jump")
equal(MacDuoMath.smooth(current: 0.99999, target: 1, dt: 0.016), 1, "the deadband snaps to the target")
equal(MacDuoMath.smooth(current: 0, target: 1, dt: -5), 0, "a negative step does nothing")
equal(MacDuoMath.decodeReport([1, 90, 0]), 90, "a valid report decodes")
equal(MacDuoMath.decodeReport([1, 0x2C, 0x01]) ?? -1, -1, "an out-of-range angle is rejected")
check(MacDuoMath.decodeReport([2, 90, 0]) == nil, "a foreign report id is rejected")
check(MacDuoMath.decodeReport([1, 90]) == nil, "a short report is rejected")
equal(MacDuoMath.decodeReport([1, 180, 0]), 180, "the upper bound decodes")

print("== 3. stillness dwell ==")
do {
    var stillness = MacDuoStillness()
    check(!stillness.observe(angle: 90, at: 0, delay: 2), "the first reading is not still")
    for step in [0.5, 1.0, 1.5, 1.9] {
        check(!stillness.observe(angle: 90, at: step, delay: 2), "before the dwell it is not still at \(step)s")
    }
    check(stillness.observe(angle: 90, at: 2.0, delay: 2), "the dwell fires exactly at the delay")
    check(!stillness.observe(angle: 93, at: 2.1, delay: 2), "a three degree move resets the anchor")
}
do {
    var stillness = MacDuoStillness()
    var now = 0.0
    var angle = 90.0
    var stillEver = false
    while now < 12 {
        angle -= 1
        now += 0.5
        stillEver = stillness.observe(angle: angle, at: now, delay: 2) || stillEver
    }
    check(!stillEver, "slow drift never reads as a stationary lid")
}
do {
    var stillness = MacDuoStillness()
    _ = stillness.observe(angle: 90, at: 0, delay: 2)
    _ = stillness.observe(angle: 90, at: 3, delay: 2)
    check(!stillness.isStill, "a gap in reports restarts the dwell")
    check(!stillness.observe(angle: nil, at: 4, delay: 2), "a lost sensor is never still")
}
do {
    var stillness = MacDuoStillness()
    var now = 0.0
    var still = stillness.observe(angle: 90, at: now, delay: 99)
    while now < 4.5 {
        now += 0.5
        still = stillness.observe(angle: 90, at: now, delay: 99)
    }
    check(!still, "the clamped five second dwell has not fired at 4.5s")
    check(stillness.observe(angle: 90, at: 5.0, delay: 99), "the delay is clamped to five seconds")
    var quick = MacDuoStillness()
    _ = quick.observe(angle: 90, at: 0, delay: 0)
    _ = quick.observe(angle: 90, at: 0.5, delay: 0)
    check(quick.observe(angle: 90, at: 1.0, delay: 0), "the delay is clamped up to one second")
}

print("== 4. frame pacing ==")
equal(MacDuoFramePacing.rate(maximum: 120, externalPower: true, lowPower: false, thermalPressure: false, moving: true), 120, "plugged in and moving allows 120 Hz")
equal(MacDuoFramePacing.rate(maximum: 120, externalPower: false, lowPower: false, thermalPressure: false, moving: true), 60, "battery settles at 60 Hz")
equal(MacDuoFramePacing.rate(maximum: 120, externalPower: true, lowPower: true, thermalPressure: false, moving: true), 60, "low power mode settles at 60 Hz")
equal(MacDuoFramePacing.rate(maximum: 120, externalPower: true, lowPower: false, thermalPressure: true, moving: true), 30, "thermal pressure caps at 30 Hz")
equal(MacDuoFramePacing.rate(maximum: 60, externalPower: true, lowPower: false, thermalPressure: false, moving: true), 60, "the display maximum is respected")
equal(MacDuoFramePacing.rate(maximum: 0, externalPower: false, lowPower: false, thermalPressure: false, moving: false), 1, "at least one frame per second")

print("== 5. animation clock ==")
do {
    var animation = MacDuoAnimation()
    equal(animation.sample(target: 1, at: 100), 0, "the first sample has no elapsed time")
    let a = animation.sample(target: 1, at: 100.016)
    let b = animation.sample(target: 1, at: 100.032)
    check(a > 0 && b > a, "the clock advances monotonically toward the target")
    animation.reset()
    equal(animation.progress, 0, "reset returns to zero")
}

print("== 5b. shared clock invariants ==")
do {
    var animation = MacDuoAnimation()
    var now = 100.0
    for _ in 0..<50 {
        now += 0.1
        animation.prime(at: now)
    }
    equal(animation.progress, 0, "priming while the overlay is hidden keeps progress at rest")
    let first = animation.sample(target: 1, at: now + 0.016)
    check(first > 0 && first < 0.5, "after five seconds of priming the first sample advances one frame, without jumping")
    var reference = MacDuoAnimation()
    reference.prime(at: 200)
    let single = reference.sample(target: 1, at: 200.016)
    near(first, single, 0.0001, "priming after idle preserves progress without jumping")
}
do {
    var shared = MacDuoAnimation()
    shared.prime(at: 0)
    var solo = MacDuoAnimation()
    solo.prime(at: 0)
    var t = 0.0
    for _ in 0..<40 {
        t += 0.016
        _ = shared.sample(target: 1, at: t)
        _ = shared.sample(target: 1, at: t)
        _ = solo.sample(target: 1, at: t)
    }
    near(shared.progress, solo.progress, 0.0001, "shared samples do not speed up the animation")
}

print("== 6. uniforms layout ==")
equal(MemoryLayout<MacDuoUniforms>.size, 32, "uniforms are 32 bytes")
equal(MacDuoUniforms().effect, MacDuoEffect.duo.shaderIndex, "the default uniform selects duo")
equal(MacDuoUniforms(progress: 0, perspective: 0, blur: 0, shadow: 0, size: SIMD2(1, 1), fadeOnly: 0, effect: 4).selectedEffect, .iris, "uniforms round-trip the effect")

print("== 7. attribution ==")
check(MacDuoAttribution.license.contains("MIT License"), "the MIT license text is embedded")
check(MacDuoAttribution.license.contains("Copyright (c) 2026 Mac Duo contributors"), "the upstream copyright is preserved")
check(MacDuoAttribution.sensorCredit.contains("LidAngleSensor"), "the lid sensor credit is preserved")
let notice = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/ThirdParty/MacDuo/LICENSE")
check(FileManager.default.fileExists(atPath: notice.path), "Resources/ThirdParty/MacDuo/LICENSE ships with the source")

print("== 8. shader source ==")
for name in ["foldVertex", "foldFragment", "foldDownsample", "foldRoll", "foldShutter", "foldFlex", "foldIris"] {
    check(MacDuoShader.source.contains(name), "the shader declares \(name)")
}
check(!MacDuoShader.source.contains("rand("), "the shader has no random taps")

func pixels(of texture: MTLTexture) -> [UInt8] {
    let count = texture.width * texture.height * 4
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { raw in
        texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return bytes
}

func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    var total = 0.0
    for i in stride(from: 0, to: a.count, by: 4) {
        total += Double(abs(Int(a[i]) - Int(b[i])))
        total += Double(abs(Int(a[i + 1]) - Int(b[i + 1])))
        total += Double(abs(Int(a[i + 2]) - Int(b[i + 2])))
    }
    return total / Double(a.count / 4 * 3)
}

func meanLuma(_ a: [UInt8]) -> Double {
    guard !a.isEmpty else { return 0 }
    var total = 0.0
    for i in stride(from: 0, to: a.count, by: 4) {
        total += (Double(a[i]) + Double(a[i + 1]) + Double(a[i + 2])) / 3
    }
    return total / Double(a.count / 4)
}

func uniforms(_ effect: MacDuoEffect, _ progress: Float, width: Int, height: Int, fadeOnly: Float = 0) -> MacDuoUniforms {
    var u = MacDuoUniforms()
    u.progress = progress
    u.effect = effect.shaderIndex
    u.size = SIMD2(Float(width), Float(height))
    u.fadeOnly = fadeOnly
    return u
}

print("== 8b. hub integration policy ==")
check(!MacDuoActivity.wanted(enabled: false, demoRunning: false, settingsVisible: false, pendingWork: false),
      "an idle module wants no sensor and no timer")
check(MacDuoActivity.wanted(enabled: true, demoRunning: false, settingsVisible: false, pendingWork: false),
      "the enabled effect keeps the sensor running")
check(MacDuoActivity.wanted(enabled: false, demoRunning: false, settingsVisible: true, pendingWork: false),
      "the open settings window keeps the sensor running")
check(MacDuoActivity.wanted(enabled: false, demoRunning: true, settingsVisible: false, pendingWork: false),
      "a running desktop test keeps the sensor running")
check(MacDuoActivity.wanted(enabled: false, demoRunning: false, settingsVisible: false, pendingWork: true),
      "pending work (permission or sensor wait) keeps the sensor running")

equal(MacDuoSensorWait.evaluate(waitingSince: nil, sensorAvailable: false, now: 10), .idle, "no wait means nothing to resolve")
equal(MacDuoSensorWait.evaluate(waitingSince: 10, sensorAvailable: false, now: 10.5), .waiting, "the first reading is given time to arrive")
equal(MacDuoSensorWait.evaluate(waitingSince: 10, sensorAvailable: true, now: 10.1), .ready, "the first reading resolves the wait")
equal(MacDuoSensorWait.evaluate(waitingSince: 10, sensorAvailable: false, now: 12), .timedOut, "a silent sensor times out instead of hanging")
equal(MacDuoSensorWait.evaluate(waitingSince: 10, sensorAvailable: false, now: 5), .waiting, "a clock that moves backwards keeps waiting")

check(MacDuoEscapeScope.consumesEscape(keyCode: MacDuoEscapeScope.escapeKeyCode, overlayVisible: true),
      "Esc is consumed while the overlay is on screen")
check(!MacDuoEscapeScope.consumesEscape(keyCode: MacDuoEscapeScope.escapeKeyCode, overlayVisible: false),
      "Esc belongs to the rest of the app when the overlay is hidden")
check(!MacDuoEscapeScope.consumesEscape(keyCode: 3, overlayVisible: true), "other keys are never swallowed")
equal(Int(MacDuoEscapeScope.escapeKeyCode), 53, "the escape key code matches kVK_Escape")

check(!MacDuoSyntheticCheck.allowsScreenCapture(syntheticCheckActive: true), "the synthetic check never starts a real screen capture")
check(MacDuoSyntheticCheck.allowsScreenCapture(syntheticCheckActive: false), "normal use may capture the desktop")
equal(MacDuoSyntheticCheck.duration(synthetic: true), 20, "the synthetic check runs for twenty seconds")
equal(MacDuoSyntheticCheck.duration(synthetic: false), 8, "the desktop test runs for eight seconds")
do {
    let honest = MacDuoSyntheticCheck.report(generatedArtworkOnly: true, screenCaptureStarted: false,
                                             overlayPresentedFrames: 12, overlayShown: true)
    equal(honest["generatedArtworkOnly"] as? Bool ?? false, true, "the report states generated artwork only")
    equal(honest["screenCaptureStarted"] as? Bool ?? true, false, "the report states no capture was started")
    equal(honest["overlayPresentedFrames"] as? Int ?? -1, 12, "the report counts presented frames")
    equal(honest["overlayShown"] as? Bool ?? false, true, "the report records whether the overlay was shown")
    let dirty = MacDuoSyntheticCheck.report(generatedArtworkOnly: false, screenCaptureStarted: true,
                                            overlayPresentedFrames: 0, overlayShown: false)
    equal(dirty["generatedArtworkOnly"] as? Bool ?? true, false, "the report cannot claim synthetic frames after a real capture")
    check(JSONSerialization.isValidJSONObject(honest), "the report serialises as JSON")
}

check(MacDuoSettingsLevel.wantsFront(overlayVisible: true, windowVisible: true, windowIsKey: true, appActive: true),
      "settings rise above the effect while the user is using that window")
check(!MacDuoSettingsLevel.wantsFront(overlayVisible: true, windowVisible: true, windowIsKey: false, appActive: true),
      "an unfocused settings window stays below the effect")
check(!MacDuoSettingsLevel.wantsFront(overlayVisible: true, windowVisible: false, windowIsKey: true, appActive: true),
      "a hidden settings window is never raised")
check(!MacDuoSettingsLevel.wantsFront(overlayVisible: false, windowVisible: true, windowIsKey: true, appActive: true),
      "without an overlay the window keeps the normal level")

print("== 8c. source guards ==")
do {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources/MacDuo")
    let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? []
    let swift = files.filter { $0.pathExtension == "swift" }
    check(swift.count >= 9, "the module sources are readable from the test")
    let text = swift.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    check(!text.contains("RegisterEventHotKey"), "the module registers no global Carbon hot key")
    check(!text.contains("InstallEventHandler"), "the module installs no application-wide Carbon handler")
    check(!text.contains("import Carbon"), "the module does not link Carbon event handling")
    check(text.contains("MacDuoSyntheticCheck.allowsScreenCapture"), "the capture path is guarded by the synthetic check")
    check(text.contains("MacDuoEscapeScope.consumesEscape"), "the local key monitor uses the scoped escape policy")
    check(text.contains("panel.ignoresMouseEvents = false"), "the overlay stays clickable as an escape route")
    let overlay = (try? String(contentsOf: sources.appendingPathComponent("MacDuoModel.swift"), encoding: .utf8)) ?? ""
    check(overlay.contains("func setSettingsVisible"), "settings visibility drives the lazy sensor")
}

print("== 9. metal render check ==")
if ProcessInfo.processInfo.environment["MACDUO_SKIP_GPU"] != nil {
    print("  skip GPU checks (MACDUO_SKIP_GPU set)")
} else if let device = MTLCreateSystemDefaultDevice() {
    do {
        let renderer = try MacDuoRenderer(device: device)
        check(true, "the metal library and both pipelines build from source")
        let width = 960
        let height = 624
        let source = try renderer.makePreviewTexture(width: width, height: height)
        let sourceBytes = pixels(of: try renderer.renderOffscreen(source: source,
            uniforms: uniforms(.duo, 0, width: width, height: height)).texture)

        var renders: [MacDuoEffect: [UInt8]] = [:]
        var worstGPU = 0.0
        for effect in MacDuoEffect.allCases {
            let open = try renderer.renderOffscreen(source: source, uniforms: uniforms(effect, 0, width: width, height: height))
            check(meanAbsoluteDifference(pixels(of: open.texture), sourceBytes) < 0.5, "\(effect.title): a fully open lid is the untouched desktop")

            let closed = try renderer.renderOffscreen(source: source, uniforms: uniforms(effect, 1, width: width, height: height))
            check(meanLuma(pixels(of: closed.texture)) < 1.0, "\(effect.title): a fully closed lid is black")

            let mid = try renderer.renderOffscreen(source: source, uniforms: uniforms(effect, 0.5, width: width, height: height))
            let midBytes = pixels(of: mid.texture)
            renders[effect] = midBytes
            worstGPU = max(worstGPU, mid.gpuMilliseconds)
            check(meanAbsoluteDifference(midBytes, sourceBytes) > 2.0, "\(effect.title): half closed differs from the desktop")

            let onset = try renderer.renderOffscreen(source: source, uniforms: uniforms(effect, 0.002, width: width, height: height))
            check(meanAbsoluteDifference(pixels(of: onset.texture), sourceBytes) < 6.0, "\(effect.title): the onset is continuous, not a flash")

            let fade = try renderer.renderOffscreen(source: source, uniforms: uniforms(effect, 0.5, width: width, height: height, fadeOnly: 1))
            check(meanLuma(pixels(of: fade.texture)) < meanLuma(sourceBytes) * 0.75, "\(effect.title): reduce motion dims instead of folding")
        }

        var distinct = true
        for a in MacDuoEffect.allCases {
            for b in MacDuoEffect.allCases where a.shaderIndex < b.shaderIndex {
                let delta = meanAbsoluteDifference(renders[a]!, renders[b]!)
                if delta < 1.5 {
                    distinct = false
                    print("    \(a.title) vs \(b.title): \(String(format: "%.2f", delta))")
                }
            }
        }
        check(distinct, "the five effects are visually distinct at half closure")

        let monotonic = MacDuoEffect.allCases.allSatisfy { effect in
            var previous = -1.0
            for step in [0.0, 0.25, 0.5, 0.75] {
                let frame = try? renderer.renderOffscreen(source: source, uniforms: uniforms(effect, Float(step), width: width, height: height))
                guard let frame else { return false }
                let delta = meanAbsoluteDifference(pixels(of: frame.texture), sourceBytes)
                if delta + 0.5 < previous { return false }
                previous = delta
            }
            return true
        }
        check(monotonic, "closing the lid moves further from the desktop, without reversals")

        let beforeCache = renderer.blurBuildCount
        _ = try renderer.renderOffscreen(source: source, uniforms: uniforms(.roll, 0.5, width: width, height: height), revision: 77)
        _ = try renderer.renderOffscreen(source: source, uniforms: uniforms(.roll, 0.6, width: width, height: height), revision: 77)
        equal(renderer.blurBuildCount - beforeCache, 1, "the blur pyramid is reused while the desktop frame is unchanged")
        _ = try renderer.renderOffscreen(source: source, uniforms: uniforms(.roll, 0.6, width: width, height: height), revision: 78)
        equal(renderer.blurBuildCount - beforeCache, 2, "a fresh desktop frame rebuilds the pyramid")

        check(worstGPU < 6.0, String(format: "gpu time at %dx%d stays under budget (%.2f ms)", width, height, worstGPU))

        let nativeWidth = 3024
        let nativeHeight = 1964
        let native = try renderer.makePreviewTexture(width: nativeWidth, height: nativeHeight)
        var nativeWorst = 0.0
        for effect in MacDuoEffect.allCases {
            var total = 0.0
            for _ in 0..<3 {
                let frame = try renderer.renderOffscreen(source: native,
                    uniforms: uniforms(effect, 0.5, width: nativeWidth, height: nativeHeight), revision: 1)
                total = max(total, frame.gpuMilliseconds)
            }
            nativeWorst = max(nativeWorst, total)
            print(String(format: "    %-8s %.2f ms", (effect.title as NSString).utf8String!, total))
        }
        check(nativeWorst < 12.0, String(format: "gpu time at %dx%d stays under budget (%.2f ms)", nativeWidth, nativeHeight, nativeWorst))
        check(MTLCreateSystemDefaultDevice()!.name.isEmpty == false, "a metal device is present")
    } catch {
        check(false, "metal render check: \(error)")
    }
} else {
    print("  skip GPU checks (no metal device)")
}

print("")
print("passes: \(passes)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
