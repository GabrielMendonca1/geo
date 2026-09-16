import AppKit
import Combine
import SwiftUI

@MainActor final class MacDuoController: NSObject, NSWindowDelegate {
    private var model: MacDuoModel?
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var activationObservers: [NSObjectProtocol] = []
    private var stateObservers: Set<AnyCancellable> = []

    var isStarted: Bool { model?.running == true }
    var isEnabled: Bool { model?.enabled == true }
    var lidAngle: Double? { model?.lidAngle }
    var sensorAvailable: Bool { model?.sensorAvailable == true }
    var effectTitle: String { (model?.effect ?? .fallback).title }
    var statusText: String { model?.status ?? "Mac Duo is off." }
    var overlayVisible: Bool { model?.overlayVisible == true }
    var onStateChange: (() -> Void)?

    private lazy var menu = MacDuoMenu { [weak self] action in self?.perform(action) }

    override init() {
        super.init()
    }

    func start() {
        let model = self.model ?? MacDuoModel()
        self.model = model
        model.overlayVisibilityChanged = { [weak self] _ in
            self?.updateSettingsLevel()
            self?.onStateChange?()
        }
        observeState(of: model)
        model.begin()
        observeActivation()
        onStateChange?()
    }

    func showSettings() {
        if model == nil { start() }
        guard let model else { return }
        model.refreshPermission()
        if window == nil { makeWindow(for: model) }
        guard let window else { return }
        fitWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.setSettingsVisible(true)
        updateSettingsLevel()
        model.wakePreview()
    }

    private func observeState(of model: MacDuoModel) {
        stateObservers.removeAll()
        let changes: [AnyPublisher<Void, Never>] = [
            model.$enabled.map { _ in () }.eraseToAnyPublisher(),
            model.$checkingPermission.map { _ in () }.eraseToAnyPublisher(),
            model.$hasPermission.map { _ in () }.eraseToAnyPublisher(),
            model.$sensorAvailable.map { _ in () }.eraseToAnyPublisher(),
            model.$status.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.onStateChange?() }
            }
            .store(in: &stateObservers)
    }

    private func observeActivation() {
        guard activationObservers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSettingsLevel() }
            })
        }
    }

    func updateSettingsLevel() {
        guard let window else { return }
        let front = MacDuoSettingsLevel.wantsFront(overlayVisible: model?.overlayVisible == true,
                                                   windowVisible: window.isVisible,
                                                   windowIsKey: window.isKeyWindow || window.isMainWindow,
                                                   appActive: NSApp.isActive)
        let level = front ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2) : .normal
        if window.level != level { window.level = level }
    }

    func stop() {
        model?.setSettingsVisible(false)
        window?.orderOut(nil)
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        window = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
        activationObservers.removeAll()
        stateObservers.removeAll()
        model?.shutdown()
        model = nil
        onStateChange?()
    }

    func toggleEffect() {
        if model == nil { start() }
        guard let model else { return }
        if model.enabled { model.pause() } else { model.enable() }
        onStateChange?()
    }

    func pause() {
        model?.pause()
        onStateChange?()
    }

    func testDesktop() {
        if model == nil { start() }
        model?.testDesktop()
    }

    func playPreview() {
        if model == nil { start() }
        model?.playPreview()
    }

    func selectEffect(_ effect: MacDuoEffect) {
        if model == nil { start() }
        model?.effect = effect
        onStateChange?()
    }

    var effect: MacDuoEffect { model?.effect ?? .fallback }

    var dwellEnabled: Bool { model?.clearWhenStill ?? true }

    var dwellSeconds: Double { model?.stillnessDelay ?? 2 }

    func setDwellEnabled(_ enabled: Bool) {
        if model == nil { start() }
        model?.clearWhenStill = enabled
        onStateChange?()
    }

    func setDwellSeconds(_ seconds: Double) {
        if model == nil { start() }
        model?.stillnessDelay = min(5, max(1, seconds.isFinite ? seconds : 2))
        onStateChange?()
    }

    func retrySensor() {
        if model == nil { start() }
        model?.retrySensor()
        onStateChange?()
    }

    func openPrivacySettings() {
        if model == nil { start() }
        model?.openPrivacy()
    }


    var menuState: MacDuoMenuState {
        let info = ProcessInfo.processInfo
        return MacDuoMenuState(started: model != nil,
                               enabled: model?.enabled == true,
                               checkingPermission: model?.checkingPermission == true,
                               waitingForSensor: model?.awaitingSensor == true,
                               sensorAvailable: model?.sensorAvailable == true,
                               hasPermission: model?.hasPermission ?? CGPreflightScreenCaptureAccess(),
                               lidAngle: model?.lidAngle,
                               effect: effect,
                               dwellEnabled: dwellEnabled,
                               dwellSeconds: dwellSeconds,
                               overlayVisible: overlayVisible,
                               status: statusText,
                               fps: model?.fps ?? 60,
                               lowPower: info.isLowPowerModeEnabled,
                               thermalPressure: info.thermalState == .serious || info.thermalState == .critical)
    }

    func menuItems() -> [NSMenuItem] { menu.items(for: menuState) }

    func menuSubmenuItem(title: String = "Mac Duo") -> NSMenuItem {
        menu.submenuItem(for: menuState, title: title)
    }

    func perform(_ action: MacDuoMenuAction) {
        switch action {
        case .toggleEffect: toggleEffect()
        case .pause: pause()
        case .selectEffect(let effect): selectEffect(effect)
        case .toggleDwell: setDwellEnabled(!dwellEnabled)
        case .selectDwell(let seconds): setDwellSeconds(Double(seconds))
        case .retrySensor: retrySensor()
        case .openPrivacy: openPrivacySettings()
        case .openSettings: showSettings()
        }
    }

    private func makeWindow(for model: MacDuoModel) {
        let content = NSHostingView(rootView: MacDuoSettingsView(model: model))
        content.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 528),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Mac Duo"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = content
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        self.window = window
        fitWindow(center: true)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWindow() }
        }
    }

    private var floatingBounds: NSRect {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        return visible.insetBy(dx: 32, dy: 32)
    }

    private func fitWindow(center: Bool = false) {
        guard let window else { return }
        let bounds = floatingBounds
        window.minSize = NSSize(width: min(900, bounds.width), height: min(530, bounds.height))
        window.maxSize = bounds.size
        var frame = window.frame
        frame.size = NSSize(width: min(center ? 940 : frame.width, bounds.width),
                            height: min(center ? 550 : frame.height, bounds.height))
        if center {
            frame.origin = NSPoint(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2)
        } else {
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: min(frameSize.width, floatingBounds.width), height: min(frameSize.height, floatingBounds.height))
    }

    func windowDidEndLiveResize(_ notification: Notification) { fitWindow() }

    func windowDidChangeScreen(_ notification: Notification) { fitWindow() }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let bounds = floatingBounds
        let size = NSSize(width: min(940, bounds.width), height: min(550, bounds.height))
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, let model else { return }
        if window.occlusionState.contains(.visible) { model.wakePreview() } else { model.previewView?.isPaused = true }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateSettingsLevel() }

    func windowDidResignKey(_ notification: Notification) { updateSettingsLevel() }

    func windowWillClose(_ notification: Notification) {
        model?.previewView?.isPaused = true
        model?.setSettingsVisible(false)
        window?.level = .normal
    }
}
