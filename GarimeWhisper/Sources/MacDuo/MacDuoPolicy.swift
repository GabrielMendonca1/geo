import Foundation

enum MacDuoActivity {
    static func wanted(enabled: Bool, demoRunning: Bool, settingsVisible: Bool, pendingWork: Bool) -> Bool {
        enabled || demoRunning || settingsVisible || pendingWork
    }
}

enum MacDuoSensorWait {
    enum Outcome: Equatable { case idle, waiting, ready, timedOut }

    static let timeout: TimeInterval = 2

    static func evaluate(waitingSince: TimeInterval?, sensorAvailable: Bool, now: TimeInterval,
                         timeout: TimeInterval = MacDuoSensorWait.timeout) -> Outcome {
        guard let waitingSince else { return .idle }
        if sensorAvailable { return .ready }
        guard now.isFinite, waitingSince.isFinite else { return .timedOut }
        if now < waitingSince { return .waiting }
        return now - waitingSince >= max(0, timeout) ? .timedOut : .waiting
    }
}

enum MacDuoEscapeScope {
    static let escapeKeyCode: UInt16 = 53

    static func consumesEscape(keyCode: UInt16, overlayVisible: Bool) -> Bool {
        overlayVisible && keyCode == escapeKeyCode
    }
}

enum MacDuoSyntheticCheck {
    static func allowsScreenCapture(syntheticCheckActive: Bool) -> Bool { !syntheticCheckActive }

    static func duration(synthetic: Bool) -> Double { synthetic ? 20 : 8 }

    static func report(generatedArtworkOnly: Bool, screenCaptureStarted: Bool,
                       overlayPresentedFrames: Int, overlayShown: Bool) -> [String: Any] {
        ["generatedArtworkOnly": generatedArtworkOnly,
         "screenCaptureStarted": screenCaptureStarted,
         "overlayPresentedFrames": overlayPresentedFrames,
         "overlayShown": overlayShown]
    }
}

enum MacDuoSettingsLevel {
    static func wantsFront(overlayVisible: Bool, windowVisible: Bool, windowIsKey: Bool, appActive: Bool) -> Bool {
        overlayVisible && windowVisible && windowIsKey && appActive
    }
}
