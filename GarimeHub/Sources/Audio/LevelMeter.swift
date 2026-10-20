import Foundation

struct LevelMeter {
    private(set) var level: Float = 0
    private(set) var peak: Float = 0

    private var peakAge: Double = 0
    private let attack: Float
    private let release: Float
    private let floorDecibels: Float
    private let holdSeconds: Double

    init(attack: Float, release: Float, floorDecibels: Float, holdSeconds: Double) {
        self.attack = min(max(attack, 0), 1)
        self.release = min(max(release, 0), 1)
        self.floorDecibels = floorDecibels
        self.holdSeconds = holdSeconds
    }

    mutating func ingest(rms: Float, peak rawPeak: Float, elapsed: Double) {
        let target = LevelMeter.normalized(rms, floorDecibels: floorDecibels)
        let coefficient = target > level ? attack : release
        level += (target - level) * coefficient

        let peakTarget = LevelMeter.normalized(rawPeak, floorDecibels: floorDecibels)
        if peakTarget >= peak {
            peak = peakTarget
            peakAge = 0
        } else {
            peakAge += elapsed
            if peakAge > holdSeconds {
                peak += (level - peak) * release
            }
        }
        peak = max(peak, level)
    }

    mutating func reset() {
        level = 0
        peak = 0
        peakAge = 0
    }

    static func normalized(_ amplitude: Float, floorDecibels: Float) -> Float {
        let magnitude = max(abs(amplitude), 1e-7)
        let decibels = 20 * log10(magnitude)
        guard decibels > floorDecibels else { return 0 }
        guard decibels < 0 else { return 1 }
        return (decibels - floorDecibels) / (-floorDecibels)
    }

    static func measure(_ samples: UnsafePointer<Float>, count: Int) -> (rms: Float, peak: Float) {
        guard count > 0 else { return (0, 0) }
        var sum: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sum += value * value
            peak = max(peak, abs(value))
        }
        return (sqrt(sum / Float(count)), peak)
    }
}
