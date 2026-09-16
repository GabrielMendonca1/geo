import AppKit
import SwiftUI
import MetalKit
import ScreenCaptureKit
import OSLog
import IOKit.ps

final class MacDuoOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MacDuoOverlayContentView: NSView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onEscape?() }

    override func rightMouseDown(with event: NSEvent) { onEscape?() }

    override func otherMouseDown(with event: NSEvent) { onEscape?() }
}

enum MacDuoDefaults {
    static let followLid = "macduo.followLid"
    static let effect = "macduo.effect"
    static let clearAngle = "macduo.clearAngle"
    static let perspective = "macduo.perspective"
    static let blur = "macduo.blur"
    static let shadow = "macduo.shadow"
    static let clearWhenStill = "macduo.clearWhenStill"
    static let stillnessDelay = "macduo.stillnessDelay"
}

@MainActor final class MacDuoModel: ObservableObject {
    @Published var lidAngle: Double?
    @Published var enabled = false
    @Published var checkingPermission = false
    @Published var status = "Preview is ready. Enable Mac Duo to use your desktop."
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var followLid = UserDefaults.standard.object(forKey: MacDuoDefaults.followLid) as? Bool ?? true {
        didSet { UserDefaults.standard.set(followLid, forKey: MacDuoDefaults.followLid) }
    }
    @Published var effect = MacDuoEffect.resolve(persisted: UserDefaults.standard.string(forKey: MacDuoDefaults.effect)) {
        didSet {
            guard oldValue != effect else { return }
            UserDefaults.standard.set(effect.persistedIdentifier, forKey: MacDuoDefaults.effect)
            wakePreview()
            update()
        }
    }
    @Published var previewAngle = 72.0
    @Published var clearAngle = UserDefaults.standard.object(forKey: MacDuoDefaults.clearAngle) as? Double ?? 105 {
        didSet { UserDefaults.standard.set(clearAngle, forKey: MacDuoDefaults.clearAngle) }
    }
    @Published var perspective = UserDefaults.standard.object(forKey: MacDuoDefaults.perspective) as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(perspective, forKey: MacDuoDefaults.perspective) }
    }
    @Published var blur = UserDefaults.standard.object(forKey: MacDuoDefaults.blur) as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(blur, forKey: MacDuoDefaults.blur) }
    }
    @Published var shadow = UserDefaults.standard.object(forKey: MacDuoDefaults.shadow) as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(shadow, forKey: MacDuoDefaults.shadow) }
    }
    @Published var clearWhenStill = UserDefaults.standard.object(forKey: MacDuoDefaults.clearWhenStill) as? Bool ?? true {
        didSet {
            guard oldValue != clearWhenStill else { return }
            UserDefaults.standard.set(clearWhenStill, forKey: MacDuoDefaults.clearWhenStill)
            resetStillness()
            updateStillnessStatus()
            update()
        }
    }
    @Published private(set) var lidIsStill = false
    @Published var stillnessDelay = min(5, max(1, UserDefaults.standard.object(forKey: MacDuoDefaults.stillnessDelay) as? Double ?? 2)) {
        didSet {
            let clamped = min(5, max(1, stillnessDelay.isFinite ? stillnessDelay : 2))
            if clamped != stillnessDelay {
                stillnessDelay = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: MacDuoDefaults.stillnessDelay)
        }
    }
    @Published var demoRunning = false
    @Published var previewPlaying = false
    @Published var sensorAvailable = false
    @Published var overlayVisible = false
    @Published var fps = 60
    @Published var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    let sensor = MacDuoLidSensor()
    let capture = MacDuoCapture()
    let device = MTLCreateSystemDefaultDevice()
    var previewRenderer: MacDuoRenderer?
    weak var previewView: MTKView?
    private var renderer: MacDuoRenderer?
    private var panel: MacDuoOverlayPanel?
    private var metalView: MTKView?
    private var timer: Timer?
    private var enableTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "ai.garime.whisper", category: "macduo")
    private var localKeyMonitor: Any?
    private var sessionActive = true
    private var systemAwake = true
    private var displayAwake = true
    private var sensorAt: TimeInterval = 0
    private var waitingForSensor = false
    private var stillness = MacDuoStillness()
    private var liveAnimation = MacDuoAnimation()
    private var powerCheckedAt: TimeInterval = -.infinity
    private var demoStart: TimeInterval?
    private var previewStart: TimeInterval?
    private var idleSince: TimeInterval?
    private var screenID: CGDirectDisplayID?
    private var notifications: [NSObjectProtocol] = []
    private var presentedFrames = 0
    private var overlayEverShown = false
    private var captureEverStarted = false
    private var syntheticCheckPath: String?
    private var syntheticCheckActive = false
    private var sensorWaitSince: TimeInterval?
    private var pendingEnableDesktopTest = false
    private(set) var running = false
    private(set) var settingsVisible = false
    var overlayVisibilityChanged: ((Bool) -> Void)?

    init() {
        sensor.onReading = { [weak self] angle in
            guard let self else { return }
            if self.lidAngle != angle { self.lidAngle = angle }
            if self.sensorAvailable != (angle != nil) { self.sensorAvailable = angle != nil }
            self.sensorAt = ProcessInfo.processInfo.systemUptime
            let settled = self.stillness.observe(angle: angle, at: self.sensorAt, delay: self.stillnessDelay)
            if self.lidIsStill != settled {
                self.lidIsStill = settled
                self.updateStillnessStatus()
            }
            if angle == nil && self.enabled { self.pause("Lid sensor unavailable. Use the preview or reconnect the sensor.") }
            self.update()
            self.resolveSensorWait(at: self.sensorAt)
        }
        capture.onFirstFrame = { [weak self] in self?.update() }
        capture.onUnavailable = { [weak self] in self?.hideOverlay() }
        capture.onFailure = { [weak self] reason in self?.pause("Capture stopped: \(reason)") }
    }

    func begin() {
        guard !running else { return }
        running = true
        observeWorkspace()
        logger.notice("Mac Duo module started; no sensor, timer or hot key is active until it is used.")
        refreshActivity()
    }

    func refreshPermission() { hasPermission = CGPreflightScreenCaptureAccess() }

    func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        refreshActivity()
    }

    var awaitingSensor: Bool { sensorWaitSince != nil }

    var activityWanted: Bool {
        MacDuoActivity.wanted(enabled: enabled, demoRunning: demoRunning, settingsVisible: settingsVisible,
                              pendingWork: checkingPermission || sensorWaitSince != nil || previewPlaying)
    }

    private func refreshActivity() {
        guard running else { return }
        if activityWanted {
            if timer == nil { sensorAt = ProcessInfo.processInfo.systemUptime }
            sensor.start()
            startTimer()
        } else {
            stopTimer()
            sensor.stop()
            if lidAngle != nil { lidAngle = nil }
            if sensorAvailable { sensorAvailable = false }
            resetStillness()
            logger.notice("Mac Duo is idle: lid sensor and the 10 Hz timer are stopped.")
        }
    }

    private func startTimer() {
        guard timer == nil, running else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var previewProgress: Double {
        if let start = previewStart {
            let t = ProcessInfo.processInfo.systemUptime - start
            if t <= 5 { return MacDuoMath.progress(angle: demoAngle(t / 5), clearAngle: clearAngle) }
        }
        if followLid { return liveProgress }
        return MacDuoMath.progress(angle: previewAngle, clearAngle: clearAngle)
    }

    func animatedProgress(preview: Bool) -> Double? {
        if preview && (!followLid || previewPlaying) { return nil }
        return liveAnimation.sample(target: overlayVisible ? liveProgress : 0,
                                    at: ProcessInfo.processInfo.systemUptime)
    }

    func wakePreview() {
        if !overlayVisible { liveAnimation.prime(at: ProcessInfo.processInfo.systemUptime) }
        if let previewView { previewRenderer?.wake(previewView) }
    }

    private func updateFrameRate(at now: TimeInterval) {
        if now - powerCheckedAt >= 2 {
            powerCheckedAt = now
            let info = ProcessInfo.processInfo
            let externalPower: Bool
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
                externalPower = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSACPowerValue
            } else { externalPower = false }
            let rate = MacDuoFramePacing.rate(maximum: builtInScreen()?.maximumFramesPerSecond ?? 60,
                externalPower: externalPower, lowPower: info.isLowPowerModeEnabled,
                thermalPressure: info.thermalState == .serious || info.thermalState == .critical, moving: true)
            if fps != rate {
                fps = rate
                logger.notice("Motion refresh cap: \(rate) Hz; capture stays at most 60 Hz.")
            }
        }
        let rate = demoRunning || !lidIsStill ? fps : min(60, fps)
        if metalView?.preferredFramesPerSecond != rate { metalView?.preferredFramesPerSecond = rate }
    }

    func uniforms(preview: Bool) -> MacDuoUniforms {
        var u = MacDuoUniforms()
        u.progress = Float(preview ? previewProgress : liveProgress)
        u.perspective = Float(perspective)
        u.blur = Float(blur)
        u.shadow = Float(shadow)
        u.fadeOnly = reducedMotion ? 1 : 0
        u.effect = effect.shaderIndex
        return u
    }

    private var demoDuration: Double { MacDuoSyntheticCheck.duration(synthetic: syntheticCheckActive) }

    var liveProgress: Double {
        guard enabled, running, sessionActive, systemAwake, displayAwake, !waitingForSensor else { return 0 }
        if let start = demoStart {
            let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / demoDuration)
            return MacDuoMath.progress(angle: demoAngle(t), clearAngle: clearAngle)
        }
        if shouldClearForStillness { return 0 }
        guard let angle = lidAngle else { return 0 }
        return MacDuoMath.progress(angle: angle, clearAngle: clearAngle)
    }

    private func demoAngle(_ t: Double) -> Double { clearAngle + 8 - sin(min(1, max(0, t)) * .pi) * (clearAngle - 12) }

    private var shouldClearForStillness: Bool { clearWhenStill && lidIsStill && !demoRunning }

    private func resetStillness() {
        stillness.reset()
        lidIsStill = false
    }

    private func updateStillnessStatus() {
        guard enabled, !demoRunning else { return }
        let still = shouldClearForStillness
        status = still
            ? "Lid is still. Move it to animate again."
            : "Following your lid. Close it gently to see the effect."
        logger.notice("Lid stillness changed: still=\(still, privacy: .public)")
    }

    func enable(startDesktopTest: Bool = false) {
        guard !checkingPermission else { return }
        begin()
        guard device != nil else {
            status = "This Mac does not have a supported Metal GPU."
            return
        }
        pendingEnableDesktopTest = startDesktopTest
        guard sensorAvailable else {
            if sensorWaitSince == nil {
                sensorWaitSince = ProcessInfo.processInfo.systemUptime
                status = "Waiting for the lid sensor…"
                refreshActivity()
            }
            return
        }
        sensorWaitSince = nil
        beginPermissionCheck(startDesktopTest: startDesktopTest)
    }

    private func resolveSensorWait(at now: TimeInterval) {
        switch MacDuoSensorWait.evaluate(waitingSince: sensorWaitSince, sensorAvailable: sensorAvailable, now: now) {
        case .idle, .waiting:
            return
        case .ready:
            sensorWaitSince = nil
            let test = pendingEnableDesktopTest
            pendingEnableDesktopTest = false
            beginPermissionCheck(startDesktopTest: test)
        case .timedOut:
            sensorWaitSince = nil
            pendingEnableDesktopTest = false
            status = "No working lid angle sensor was found. The preview still works."
            logger.notice("Enable aborted: the lid sensor never reported.")
            refreshActivity()
        }
    }

    private func beginPermissionCheck(startDesktopTest: Bool) {
        guard !checkingPermission, !enabled else { return }
        pendingEnableDesktopTest = false
        checkingPermission = true
        refreshActivity()
        status = "Checking screen access…"
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingPermission = false }
            do {
                try await capture.verifyAccess()
                guard !Task.isCancelled else { return }
                self.hasPermission = true
                self.enabled = true
                self.status = "Following your lid. Close it gently to see the effect."
                self.updateStillnessStatus()
                self.logger.notice("Enable succeeded: ScreenCaptureKit access verified.")
                self.refreshActivity()
                if startDesktopTest { self.beginDesktopTest() } else { self.update() }
            } catch {
                guard !Task.isCancelled else { return }
                self.enabled = false
                let failure = error as NSError
                if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
                    self.hasPermission = false
                    self.status = "Screen access was not accepted. Remove any old GarimeWhisper entry in Screen Recording, allow it again, then quit and reopen the app."
                } else {
                    self.status = "Could not enable screen capture: \(error.localizedDescription)"
                }
                self.logger.error("Enable failed: \(failure.domain, privacy: .public) / \(failure.code)")
                self.refreshActivity()
            }
        }
    }

    func pause(_ message: String = "Paused. Your desktop is clear.") {
        enableTask?.cancel()
        enableTask = nil
        checkingPermission = false
        sensorWaitSince = nil
        pendingEnableDesktopTest = false
        enabled = false
        demoStart = nil
        demoRunning = false
        hideOverlay()
        capture.stop()
        finishSyntheticCheck()
        status = message
        logger.notice("Mac Duo paused: \(message, privacy: .public)")
        refreshActivity()
    }

    func playPreview() {
        begin()
        previewStart = ProcessInfo.processInfo.systemUptime
        previewPlaying = true
        refreshActivity()
        wakePreview()
    }

    func testDesktop() {
        if !enabled {
            enable(startDesktopTest: true)
            return
        }
        beginDesktopTest()
    }

    private func beginDesktopTest() {
        demoStart = ProcessInfo.processInfo.systemUptime
        demoRunning = true
        status = "Eight-second desktop test. Press Esc or click the screen to stop."
        refreshActivity()
        update()
    }

    func checkOverlay(output: String?) {
        do {
            guard let screen = builtInScreen(), let device else { throw MacDuoError.message("Built-in display or GPU unavailable.") }
            begin()
            syntheticCheckActive = true
            syntheticCheckPath = output
            captureEverStarted = false
            overlayEverShown = false
            try prepareOverlay(on: screen)
            let factory = try MacDuoRenderer(device: device)
            capture.frames.put(try factory.makeSyntheticFrame())
            presentedFrames = 0
            enabled = true
            demoStart = ProcessInfo.processInfo.systemUptime
            demoRunning = true
            status = "Testing the overlay with generated artwork. Esc or a click stops the test."
            refreshActivity()
            update()
        } catch {
            pause(error.localizedDescription)
        }
    }

    private func finishSyntheticCheck() {
        guard syntheticCheckActive else { return }
        let path = syntheticCheckPath
        syntheticCheckActive = false
        syntheticCheckPath = nil
        guard let path else { return }
        let report = MacDuoSyntheticCheck.report(generatedArtworkOnly: !captureEverStarted,
                                                 screenCaptureStarted: captureEverStarted,
                                                 overlayPresentedFrames: presentedFrames,
                                                 overlayShown: overlayEverShown)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func retrySensor() {
        sensor.stop()
        sensor.start()
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) != 0 && CGDisplayIsActive(n.uint32Value) != 0
        }
    }

    private func prepareOverlay(on screen: NSScreen) throws {
        guard let device else { throw MacDuoError.message("Metal is unavailable.") }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        if screenID != displayID || panel?.frame != screen.frame {
            hideOverlay()
            panel?.close()
            panel = nil
            renderer = nil
            metalView = nil
            capture.stop()
        }
        screenID = displayID
        guard panel == nil else { return }
        let panel = MacDuoOverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false, screen: screen)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.setFrame(screen.frame, display: false)
        let renderer = try MacDuoRenderer(device: device)
        renderer.frames = capture.frames
        renderer.parameters = { [weak self] in self?.uniforms(preview: false) ?? MacDuoUniforms() }
        renderer.animatedProgress = { [weak self] in self?.animatedProgress(preview: false) }
        renderer.onFailure = { [weak self] reason in self?.pause(reason) }
        renderer.onPresented = { [weak self] in
            guard let self, self.enabled, self.overlayVisible, self.capture.frames.get().0 != nil else { return }
            self.panel?.alphaValue = 1
            self.presentedFrames += 1
            if self.presentedFrames == 1 { self.logger.notice("Overlay presented a completed GPU frame.") }
        }
        let content = MacDuoOverlayContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.autoresizesSubviews = true
        content.onEscape = { [weak self] in
            self?.pause("Stopped by a click on the effect. Your desktop is clear.")
        }
        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        renderer.configure(view)
        view.isPaused = true
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        panel.contentView = content
        self.panel = panel
        self.metalView = view
        self.renderer = renderer
    }

    private func update() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        resolveSensorWait(at: now)
        updateFrameRate(at: now)
        if !overlayVisible { liveAnimation.prime(at: now) }
        if let start = previewStart, now - start > 5 {
            previewStart = nil
            previewPlaying = false
            previewAngle = clearAngle + 8
            refreshActivity()
        }
        if let start = demoStart, now - start > demoDuration {
            demoStart = nil
            demoRunning = false
            if syntheticCheckActive {
                pause("Overlay check finished. Your desktop is clear.")
                return
            }
            status = "Desktop test finished. Following your lid."
            updateStillnessStatus()
            refreshActivity()
        }
        guard enabled, sessionActive, systemAwake, displayAwake else { return }
        if now - sensorAt > 1 {
            hideOverlay()
            if capture.isRunning { capture.stop() }
            if !waitingForSensor {
                waitingForSensor = true
                status = "Waiting for the lid sensor. Your desktop is clear."
                logger.notice("Sensor reports delayed; the overlay is hidden.")
            }
            return
        }
        if waitingForSensor {
            waitingForSensor = false
            logger.notice("Sensor reports resumed.")
            updateStillnessStatus()
        }
        guard let screen = builtInScreen(),
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsInMirrorSet(display.uint32Value) == 0 else {
            pause("Mac Duo needs an active, unmirrored built-in display.")
            return
        }
        let target = liveProgress
        let shouldCapture = demoRunning || (!shouldClearForStillness && (lidAngle ?? 180) < clearAngle + 14)
        if shouldCapture {
            idleSince = nil
            do { try prepareOverlay(on: screen) } catch {
                pause(error.localizedDescription)
                return
            }
            if !capture.isRunning, MacDuoSyntheticCheck.allowsScreenCapture(syntheticCheckActive: syntheticCheckActive) {
                let width = Int(screen.frame.width * screen.backingScaleFactor)
                let height = Int(screen.frame.height * screen.backingScaleFactor)
                captureEverStarted = true
                Task {
                    guard enabled, sessionActive, systemAwake, displayAwake, !shouldClearForStillness,
                          ProcessInfo.processInfo.systemUptime - sensorAt <= 1 else { return }
                    do { try await capture.start(displayID: display.uint32Value, width: width, height: height, fps: min(60, fps)) }
                    catch { if enabled { pause("Cannot capture the desktop: \(error.localizedDescription)") } }
                }
            }
        } else if capture.isRunning {
            if idleSince == nil { idleSince = now }
            if now - (idleSince ?? now) > 1.2 && !overlayVisible { capture.stop() }
        }
        if target > 0.0001, capture.frames.get().0 != nil {
            if !overlayVisible {
                installEscapeMonitor()
                renderer?.resetProgress(to: 0)
                liveAnimation.reset()
                panel?.alphaValue = 0
                overlayVisible = true
                overlayEverShown = true
                overlayVisibilityChanged?(true)
                panel?.orderFrontRegardless()
                metalView?.isPaused = false
                if let metalView { renderer?.draw(in: metalView) }
            }
        } else if overlayVisible, (renderer?.progress ?? 0) < 0.0002 || capture.frames.get().0 == nil {
            hideOverlay()
        }
        if shouldClearForStillness && !overlayVisible && capture.isRunning {
            capture.stop()
            idleSince = nil
        }
    }

    private func hideOverlay() {
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        metalView?.isPaused = true
        overlayVisible = false
        liveAnimation.reset()
        overlayVisibilityChanged?(false)
        removeEscapeMonitor()
    }

    private func installEscapeMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard MacDuoEscapeScope.consumesEscape(keyCode: event.keyCode, overlayVisible: self.overlayVisible) else { return event }
            self.pause("Stopped with Esc. Your desktop is clear.")
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let localKeyMonitor else { return }
        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
    }

    private func observeWorkspace() {
        guard notifications.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        notifications.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logger.notice("Desktop changed; the overlay was hidden.")
                self.hideOverlay()
                self.capture.stop()
                self.update()
            }
        })
        let sleepEvents: [(Notification.Name, Int)] = [
            (NSWorkspace.willSleepNotification, 0), (NSWorkspace.screensDidSleepNotification, 1),
            (NSWorkspace.sessionDidResignActiveNotification, 2)]
        let wakeEvents: [(Notification.Name, Int)] = [
            (NSWorkspace.didWakeNotification, 0), (NSWorkspace.screensDidWakeNotification, 1),
            (NSWorkspace.sessionDidBecomeActiveNotification, 2)]
        for (name, kind) in sleepEvents {
            notifications.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if kind == 0 { self.systemAwake = false }
                    if kind == 1 { self.displayAwake = false }
                    if kind == 2 { self.sessionActive = false }
                    self.resetStillness()
                    self.hideOverlay()
                    self.capture.stop()
                    self.sensor.stop()
                }
            })
        }
        for (name, kind) in wakeEvents {
            notifications.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if kind == 0 { self.systemAwake = true }
                    if kind == 1 { self.displayAwake = true }
                    if kind == 2 { self.sessionActive = true }
                    guard self.systemAwake, self.displayAwake, self.sessionActive, self.running else { return }
                    self.lidAngle = nil
                    self.sensorAt = ProcessInfo.processInfo.systemUptime
                    self.resetStillness()
                    self.updateStillnessStatus()
                    self.refreshActivity()
                }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideOverlay()
                self?.capture.stop()
                self?.panel?.close()
                self?.panel = nil
                self?.screenID = nil
            }
        })
        notifications.append(nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
    }

    func shutdown() {
        settingsVisible = false
        pause("Mac Duo is off.")
        sensor.stop()
        stopTimer()
        panel?.contentView = nil
        panel?.close()
        panel = nil
        metalView = nil
        renderer = nil
        previewRenderer = nil
        previewView = nil
        removeEscapeMonitor()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in notifications {
            workspaceCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        notifications.removeAll()
        running = false
    }
}
