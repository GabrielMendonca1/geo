import Foundation

enum IconState: Equatable {
    case idle
    case starting
    case listening
    case recording
    case transcribing
    case flushing
    case meeting
    case success
    case error
    case cancelled
}

enum IconOverlay: Hashable {
    case alert
    case moon
}

enum IconTint: Equatable {
    case neutral
    case live
    case work
    case good
    case warn
}

enum IconRender: Equatable {
    case symbol(String)
    case triangle
    case triangleLevel
    case triangleBeat
    case triangleSweep
    case spinner
    case blocked
}

struct IconPlan: Equatable {
    let render: IconRender
    let tint: IconTint
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
            return still(.triangle, tint: .neutral)
        case .success:
            return still(.triangle, tint: .good)
        case .error:
            return still(.symbol("exclamationmark.triangle.fill"), tint: .warn)
        case .cancelled:
            return IconPlan(
                render: .blocked,
                tint: .neutral,
                frameCount: 1,
                interval: 0,
                repeats: false,
                levelDriven: false,
                minimumRedrawInterval: 0,
                followUp: .idle,
                followUpDelay: Config.iconCancelledSeconds
            )
        case .starting:
            guard !reduceMotion else { return still(.triangle, tint: .live) }
            return IconPlan(
                render: .triangleBeat,
                tint: .live,
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
                render: .triangleLevel,
                tint: .live,
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
        case .meeting:
            guard !reduceMotion else { return still(.triangle, tint: .live) }
            return IconPlan(
                render: .triangleBeat,
                tint: .live,
                frameCount: Config.iconBeatFrames,
                interval: Config.iconBeatInterval,
                repeats: true,
                levelDriven: false,
                minimumRedrawInterval: 0,
                followUp: nil,
                followUpDelay: 0
            )
        case .transcribing, .flushing:
            guard !reduceMotion else {
                return IconPlan(
                    render: .spinner,
                    tint: .work,
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
                render: .triangleSweep,
                tint: .work,
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

    static func triangleScale(level: Float, peak: Float) -> Double {
        let clamped = Double(min(max(level, 0), 1))
        let ceiling = Double(min(max(max(peak, level), 0), 1))
        let floor = 0.74
        let value = floor + (1 - floor) * clamped
        return min(max(value, floor), max(floor + (1 - floor) * ceiling, floor))
    }

    static func beatScale(frame: Int, frameCount: Int) -> Double {
        guard frameCount > 1 else { return 1 }
        let phase = Double(frame % frameCount) / Double(frameCount)
        let wave = (1 - cos(phase * 2 * Double.pi)) / 2
        return 0.82 + 0.18 * wave
    }

    private static func still(_ render: IconRender, tint: IconTint) -> IconPlan {
        IconPlan(
            render: render,
            tint: tint,
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
