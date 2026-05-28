import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "GlobalHotkeyManager")

class GlobalHotkeyManager {
    private enum PasteDestination {
        case currentTarget
        case externalApp(NSRunningApplication)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    private var retryDelay: TimeInterval = 2
    private static let minRetryDelay: TimeInterval = 2
    private static let maxRetryDelay: TimeInterval = 60
    private let pasteLock = NSLock()
    private var _isSimulatingPaste = false
    private var isSimulatingPaste: Bool {
        get { pasteLock.lock(); defer { pasteLock.unlock() }; return _isSimulatingPaste }
        set { pasteLock.lock(); _isSimulatingPaste = newValue; pasteLock.unlock() }
    }
    private var lastExternalApplication: NSRunningApplication?
    private let navigateToTab: (AppTab) -> Void
    private let screenshotWatcher: ScreenshotWatcher
    private let logStore: LogStore

    init(
        screenshotWatcher: ScreenshotWatcher,
        logStore: LogStore,
        navigateToTab: @escaping (AppTab) -> Void = { _ in }
    ) {
        self.screenshotWatcher = screenshotWatcher
        self.logStore = logStore
        self.navigateToTab = navigateToTab
        self.lastExternalApplication = Self.currentExternalApplication()
        observeActiveApplications()
    }

    deinit {
        stopMonitoring()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func startMonitoring() {
        guard eventTap == nil else {
            startHealthTimer()
            return
        }

        if !AXIsProcessTrusted() {
            logger.warning("Accessibility permission missing; hotkeys will not work.")
            startHealthTimer()
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    logger.warning("Event tap disabled (\(type.rawValue)); re-enabled")
                }
                return nil
            }
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create event tap. Will retry. Check Accessibility permissions.")
            retryDelay = min(Self.maxRetryDelay, max(retryDelay, Self.minRetryDelay) * 2)
            startHealthTimer()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Event tap started successfully")
        retryDelay = Self.minRetryDelay
        startHealthTimer()
    }

    private func startHealthTimer() {
        healthTimer?.cancel()
        let interval: TimeInterval = (eventTap != nil) ? 5 : retryDelay
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let tap = self.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    logger.warning("Event tap found disabled; re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return
            }
            if AXIsProcessTrusted() {
                self.startMonitoring()
                return
            }
            self.retryDelay = min(Self.maxRetryDelay, self.retryDelay * 2)
            self.startHealthTimer()
        }
        healthTimer = timer
        timer.resume()
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        return self.processEvent(type: type, event: event)
    }

    func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        if isSimulatingPaste {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let hasCmd = flags.contains(.maskCommand)
        guard hasCmd else { return Unmanaged.passRetained(event) }

        let hasShift = flags.contains(.maskShift)
        let hasCtrl = flags.contains(.maskControl)
        let hasOpt = flags.contains(.maskAlternate)

        if hasShift && !hasCtrl && !hasOpt {
            switch keyCode {
            case 9:
                let isRecent = Date().timeIntervalSince(screenshotWatcher.lastProcessedTime) < 60
                if isRecent {
                    self.pasteLatestText(isRecent: isRecent)
                    return nil
                }

            case 0:
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                    self.navigateToTab(.ai)
                }
                return nil

            default:
                break
            }
        }

        if !hasShift && !hasCtrl && !hasOpt && keyCode == 9 {
            let isRecent = Date().timeIntervalSince(screenshotWatcher.lastProcessedTime) < 60
            if isRecent, let image = screenshotWatcher.lastCapturedImage {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                if let tiff = image.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                    if let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        item.setData(png, forType: .png)
                    }
                }
                if let text = screenshotWatcher.lastOCRText, !text.isEmpty {
                    item.setString(text, forType: .string)
                }
                if let fileURL = screenshotWatcher.lastProcessedURL {
                    item.setString(fileURL.absoluteString, forType: .fileURL)
                }
                pasteboard.writeObjects([item])
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func getLatestText() -> String? {
        if let latest = screenshotWatcher.lastOCRText, !latest.isEmpty {
            return latest
        }
        let captures = MainActor.assumeIsolated { logStore.captures }
        if let capture = captures.first(where: {
            $0.extractedText != nil && !$0.extractedText!.isEmpty
        }), let text = capture.extractedText {
            return text
        }
        return nil
    }

    private func simulatePasteCommand() {
        isSimulatingPaste = true

        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let cmdFlag = CGEventFlags.maskCommand

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            isSimulatingPaste = false
            return
        }

        keyDown.flags = cmdFlag
        keyUp.flags = cmdFlag

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSimulatingPaste = false
        }
    }

    private func pasteLatestText(isRecent: Bool = true, retryCount: Int = 0) {
        if let text = getLatestText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                switch self.preferredPasteDestination() {
                case .currentTarget:
                    self.simulatePasteCommand()
                case .externalApp(let application):
                    self.simulatePasteCommand(afterActivating: application)
                }
            }
            return
        }

        if isRecent && retryCount < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pasteLatestText(isRecent: isRecent, retryCount: retryCount + 1)
            }
            return
        }

        return
    }

    func stopMonitoring() {
        healthTimer?.cancel()
        healthTimer = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private func observeActiveApplications() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != Self.currentProcessIdentifier else {
                return
            }

            self.lastExternalApplication = application
        }
    }

    private func preferredPasteDestination() -> PasteDestination {
        guard NSApp.isActive,
              !hasLocalEditableTarget(),
              let application = lastExternalApplication,
              !application.isTerminated else {
            return .currentTarget
        }

        return .externalApp(application)
    }

    private func hasLocalEditableTarget() -> Bool {
        guard NSApp.isActive,
              let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        if let textView = responder as? NSTextView {
            return textView.isEditable
        }

        return false
    }

    private func simulatePasteCommand(afterActivating application: NSRunningApplication) {
        isSimulatingPaste = true

        DispatchQueue.main.async {
            if !application.isTerminated {
                application.activate()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.postPasteCommand()
            }
        }
    }

    private func postPasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let cmdFlag = CGEventFlags.maskCommand

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            isSimulatingPaste = false
            return
        }

        keyDown.flags = cmdFlag
        keyUp.flags = cmdFlag

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSimulatingPaste = false
        }
    }

    private static var currentProcessIdentifier: pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    private static func currentExternalApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != currentProcessIdentifier else {
            return nil
        }

        return application
    }
}
