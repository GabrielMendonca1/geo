import Foundation

enum MacDuoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum MacDuoEffect: String, CaseIterable, Sendable, Identifiable {
    case duo, roll, shutter, flex, iris

    static let fallback = MacDuoEffect.duo

    var id: String { rawValue }
    var persistedIdentifier: String { rawValue }

    var shaderIndex: UInt32 {
        switch self {
        case .duo: return 0
        case .roll: return 1
        case .shutter: return 2
        case .flex: return 3
        case .iris: return 4
        }
    }

    static func resolve(persisted: String?) -> MacDuoEffect {
        guard let persisted, let effect = MacDuoEffect(rawValue: persisted) else { return fallback }
        return effect
    }

    static func resolve(shaderIndex: UInt32) -> MacDuoEffect {
        allCases.first { $0.shaderIndex == shaderIndex } ?? fallback
    }

    var title: String {
        switch self {
        case .duo: return "Duo"
        case .roll: return "Roll"
        case .shutter: return "Shutter"
        case .flex: return "Flex"
        case .iris: return "Iris"
        }
    }

    var symbol: String {
        switch self {
        case .duo: return "macbook"
        case .roll: return "scroll"
        case .shutter: return "square.stack.3d.down.right"
        case .flex: return "rectangle.compress.vertical"
        case .iris: return "camera.aperture"
        }
    }

    var summary: String {
        switch self {
        case .duo: return "The desktop swells around the hinge as the lid closes."
        case .roll: return "The desktop curls into a roll that travels down to the hinge."
        case .shutter: return "Four rigid panels telescope behind each other into the hinge."
        case .flex: return "One bowing flexible display collapses toward the hinge."
        case .iris: return "Eight overlapping blades close an aperture above the hinge."
        }
    }

    var needsPrefilteredSource: Bool { self != .duo }
}

enum MacDuoMath {
    static func progress(angle: Double, clearAngle: Double) -> Double {
        guard angle.isFinite, clearAngle.isFinite else { return 0 }
        let clear = min(140, max(60, clearAngle))
        let t = min(1, max(0, (clear - angle) / (clear - 5)))
        return t * t * (3 - 2 * t)
    }

    static func smooth(current: Double, target: Double, dt: Double) -> Double {
        guard current.isFinite, target.isFinite, dt.isFinite else { return 0 }
        let t = min(1, max(0, target))
        let next = current + (t - current) * (1 - exp(-max(0, dt) / 0.045))
        return abs(next - t) < 0.0001 ? t : next
    }

    static func decodeReport(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == 1 else { return nil }
        let angle = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard (0...180).contains(angle) else { return nil }
        return Double(angle)
    }
}

struct MacDuoAnimation {
    private(set) var progress: Double = 0
    private var lastTime: TimeInterval?

    init() {}

    mutating func reset() { self = MacDuoAnimation() }

    mutating func prime(at now: TimeInterval) { lastTime = now }

    mutating func sample(target: Double, at now: TimeInterval) -> Double {
        let dt = lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
        progress = MacDuoMath.smooth(current: progress, target: target, dt: dt)
        lastTime = now
        return progress
    }
}

enum MacDuoFramePacing {
    static func rate(maximum: Int, externalPower: Bool, lowPower: Bool, thermalPressure: Bool, moving: Bool) -> Int {
        let cap = thermalPressure ? 30 : (externalPower && !lowPower && moving ? 120 : 60)
        return max(1, min(maximum, cap))
    }
}

struct MacDuoStillness {
    private(set) var isStill = false
    private var anchor: Double?
    private var stationarySince: TimeInterval?
    private var lastReadingAt: TimeInterval?

    init() {}

    mutating func reset() { self = MacDuoStillness() }

    @discardableResult
    mutating func observe(angle: Double?, at now: TimeInterval, delay: TimeInterval = 2) -> Bool {
        guard let angle, angle.isFinite, (0...180).contains(angle), now.isFinite else {
            reset()
            return false
        }
        if let previous = lastReadingAt, now < previous || now - previous > 1 { reset() }
        lastReadingAt = now
        let interval = delay.isFinite ? min(5, max(1, delay)) : 2
        if anchor == nil || abs(angle - anchor!) >= 2 {
            anchor = angle
            stationarySince = now
            isStill = false
        } else if let since = stationarySince, now - since >= interval {
            isStill = true
        }
        return isStill
    }
}
