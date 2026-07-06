import AVFoundation

@MainActor
final class AudioSessionManager {
    private let session = AVAudioSession.sharedInstance()
    private var interruptionToken: NSObjectProtocol?
    private var routeChangeToken: NSObjectProtocol?

    var onInterruption: ((Bool) -> Void)?
    var onRouteChange: (() -> Void)?

    func activateConversation() throws {
        let bluetoothTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let hasBluetooth = session.currentRoute.outputs.contains { bluetoothTypes.contains($0.portType) }
        var options: AVAudioSession.CategoryOptions = [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
        if !hasBluetooth { options.insert(.defaultToSpeaker) }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        startObserving()
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startObserving() {
        guard interruptionToken == nil else { return }
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.onInterruption?(type == .began)
            }
        }
        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onRouteChange?() }
        }
    }

    deinit {
        if let interruptionToken { NotificationCenter.default.removeObserver(interruptionToken) }
        if let routeChangeToken { NotificationCenter.default.removeObserver(routeChangeToken) }
    }
}
