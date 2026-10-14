import AppKit
import Foundation

final class FeedbackSettingsController: NSObject, NSWindowDelegate {
    static let shared = FeedbackSettingsController()

    private var window: NSWindow?
    private var toggle: NSButton?
    private var slider: NSSlider?
    private var readout: NSTextField?
    private var testButton: NSButton?
    private var note: NSTextField?
    private var refresh: Timer?

    static func captureNote(reasons: [String]) -> String {
        guard !reasons.isEmpty else { return "Sons liberados — silenciados durante gravação" }
        return "Silenciado: " + reasons.joined(separator: ", ")
    }

    func present() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.present() }
            return
        }
        let panel = window ?? build()
        window = panel
        sync()
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        startRefresh()
    }

    private func build() -> NSWindow {
        let width: CGFloat = 320
        let height: CGFloat = 172
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        panel.title = "Sons de interface"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let check = NSButton(checkboxWithTitle: "Ativar sons", target: self, action: #selector(toggleChanged(_:)))
        check.frame = NSRect(x: 24, y: height - 52, width: width - 48, height: 22)
        content.addSubview(check)
        toggle = check

        let label = NSTextField(labelWithString: "Volume")
        label.frame = NSRect(x: 24, y: height - 92, width: 70, height: 20)
        content.addSubview(label)

        let control = NSSlider(value: FeedbackVolume.fallback,
                               minValue: FeedbackVolume.minimum,
                               maxValue: FeedbackVolume.maximum,
                               target: self,
                               action: #selector(volumeChanged(_:)))
        control.frame = NSRect(x: 96, y: height - 92, width: width - 168, height: 20)
        control.isContinuous = true
        content.addSubview(control)
        slider = control

        let value = NSTextField(labelWithString: "")
        value.alignment = .right
        value.frame = NSRect(x: width - 68, y: height - 92, width: 44, height: 20)
        content.addSubview(value)
        readout = value

        let test = NSButton(title: "Testar", target: self, action: #selector(testPressed(_:)))
        test.bezelStyle = .rounded
        test.frame = NSRect(x: width - 128, y: 24, width: 104, height: 28)
        content.addSubview(test)
        testButton = test

        let status = NSTextField(labelWithString: FeedbackSettingsController.captureNote(reasons: []))
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 24, y: 28, width: width - 160, height: 18)
        content.addSubview(status)
        note = status

        panel.contentView = content
        return panel
    }

    private func sync() {
        let feedback = SoundFeedback.shared
        let reasons = feedback.captureReasons
        toggle?.state = feedback.isEnabled ? .on : .off
        slider?.doubleValue = feedback.volume
        slider?.isEnabled = feedback.isEnabled
        readout?.stringValue = FeedbackSettingsController.format(feedback.volume)
        note?.stringValue = FeedbackSettingsController.captureNote(reasons: reasons)
        testButton?.isEnabled = reasons.isEmpty && feedback.isEnabled
            && !FeedbackVolume.isSilent(feedback.volume)
    }

    private func startRefresh() {
        refresh?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else {
                self?.stopRefresh()
                return
            }
            self.sync()
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    private func stopRefresh() {
        refresh?.invalidate()
        refresh = nil
    }

    static func format(_ volume: Double) -> String {
        let ratio = FeedbackVolume.maximum > 0 ? volume / FeedbackVolume.maximum : 0
        return "\(Int((ratio * 100).rounded()))%"
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        SoundFeedback.shared.isEnabled = sender.state == .on
        sync()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        SoundFeedback.shared.volume = sender.doubleValue
        readout?.stringValue = FeedbackSettingsController.format(SoundFeedback.shared.volume)
    }

    @objc private func testPressed(_ sender: NSButton) {
        SoundFeedback.shared.play(.selection)
    }

    func windowWillClose(_ notification: Notification) {
        stopRefresh()
        sync()
    }
}

extension SoundFeedback {
    func showSettings() {
        FeedbackSettingsController.shared.present()
    }
}
