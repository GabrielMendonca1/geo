import Foundation

enum FeedbackVolume {
    static let minimum: Double = 0
    static let maximum: Double = 0.45
    static let fallback: Double = 0.18
    static let silenceThreshold: Double = 0.01

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return fallback }
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }

    static func isSilent(_ value: Double) -> Bool {
        clamp(value) < silenceThreshold
    }
}

enum FeedbackDefaultsKey {
    static let enabled = "ai.garime.hub.feedback.enabled"
    static let volume = "ai.garime.hub.feedback.volume"
}

struct FeedbackPreferences {
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
    }

    var enabled: Bool {
        get { store.object(forKey: FeedbackDefaultsKey.enabled) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: FeedbackDefaultsKey.enabled) }
    }

    var volume: Double {
        get {
            guard let raw = store.object(forKey: FeedbackDefaultsKey.volume) as? Double else {
                return FeedbackVolume.fallback
            }
            return FeedbackVolume.clamp(raw)
        }
        nonmutating set { store.set(FeedbackVolume.clamp(newValue), forKey: FeedbackDefaultsKey.volume) }
    }
}
