import Foundation

enum IconState: Equatable {
    case idle
    case starting
    case listening
    case recording
    case transcribing
    case flushing
    case success
    case error
    case cancelled
}

enum IconRender: Equatable {
    case symbol(String)
    case bars
    case pulse
    case spinner
    case blocked
}

struct IconPlan: Equatable {
    let render: IconRender
    let frameCount: Int
    let interval: TimeInterval
    let repeats: Bool
    let levelDriven: Bool
    let minimumRedrawInterval: TimeInterval
    let followUp: IconState?
    let followUpDelay: TimeInterval

    var isAnimated: Bool { frameCount > 1 && interval > 0 }
}

enum IconAnimation {
    static func plan(for state: IconState, reduceMotion: Bool) -> IconPlan {
        switch state {
        case .idle:
            return still(.symbol("mic"))
        case .success:
            return still(.symbol("checkmark.circle"))
        case .error:
            return still(.symbol("exclamationmark.triangle"))
        case .cancelled:
            return IconPlan(
                render: .blocked,
                frameCount: 1,
                interval: 0,
                repeats: false,
                levelDriven: false,
                minimumRedrawInterval: 0,
                followUp: .idle,
                followUpDelay: Config.iconCancelledSeconds
            )
        case .starting:
            guard !reduceMotion else { return still(.symbol("mic.fill")) }
            return IconPlan(
                render: .pulse,
                frameCount: Config.iconPulseFrames,
                interval: Config.iconPulseInterval,
                repeats: false,
                levelDriven: false,
                minimumRedrawInterval: 0,
                followUp: nil,
                followUpDelay: 0
            )
        case .listening, .recording:
            return IconPlan(
                render: .bars,
                frameCount: 1,
                interval: 0,
                repeats: false,
                levelDriven: true,
                minimumRedrawInterval: reduceMotion
                    ? Config.iconReducedLevelInterval
                    : Config.iconLevelInterval,
                followUp: nil,
                followUpDelay: 0
            )
        case .transcribing, .flushing:
            guard !reduceMotion else {
                return IconPlan(
                    render: .spinner,
                    frameCount: 2,
                    interval: Config.iconReducedBlinkInterval,
                    repeats: true,
                    levelDriven: false,
                    minimumRedrawInterval: 0,
                    followUp: nil,
                    followUpDelay: 0
                )
            }
            return IconPlan(
                render: .spinner,
                frameCount: Config.iconSpinnerFrames,
                interval: Config.iconSpinnerInterval,
                repeats: true,
                levelDriven: false,
                minimumRedrawInterval: 0,
                followUp: nil,
                followUpDelay: 0
            )
        }
    }

    static func barHeights(level: Float, peak: Float, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let clampedLevel = Double(min(max(level, 0), 1))
        let clampedPeak = Double(min(max(max(peak, level), 0), 1))
        let floor = 0.14
        return (0..<count).map { index in
            let weight = profile(index: index, count: count)
            let value = floor + (1 - floor) * clampedLevel * weight
            let ceiling = floor + (1 - floor) * clampedPeak
            return min(max(value, floor), max(ceiling, floor))
        }
    }

    static func profile(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let center = Double(count - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 1 - 0.45 * distance
    }

    private static func still(_ render: IconRender) -> IconPlan {
        IconPlan(
            render: render,
            frameCount: 1,
            interval: 0,
            repeats: false,
            levelDriven: false,
            minimumRedrawInterval: 0,
            followUp: nil,
            followUpDelay: 0
        )
    }
}
