import AppKit

enum CapsState {
    static func isOn(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.capsLock)
    }

    static func isOn(rawEventFlags: UInt64) -> Bool {
        rawEventFlags & CGEventFlags.maskAlphaShift.rawValue != 0
    }
}

final class CapsWatcher {
    private var timer: Timer?
    private var monitor: Any?
    private var last = false
    private let onChange: (Bool) -> Void

    private(set) var isOn = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        poll()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] _ in
            self?.poll()
        }
        let ticker = Timer(timeInterval: Config.capsPollSeconds, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let on = CapsState.isOn(rawEventFlags: flags.rawValue)
        isOn = on
        guard on != last else { return }
        last = on
        onChange(on)
    }

    deinit {
        stop()
    }
}
