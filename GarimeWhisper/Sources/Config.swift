import Foundation

enum Config {
    static let whisperBinary = "/opt/homebrew/bin/whisper-cli"
    static let ffmpegBinary = "/opt/homebrew/bin/ffmpeg"
    static let modelPath = NSHomeDirectory() + "/.cache/whisper/ggml-large-v3-turbo.bin"
    static let language = "pt"
    static let maxRecordingSeconds: TimeInterval = 120
    static let minRecordingSeconds: TimeInterval = 0.4
    static let transcribeTimeout: TimeInterval = 180
    static let pasteRestoreDelay: TimeInterval = 0.8
    static let workDirectory: String = {
        let override = ProcessInfo.processInfo.environment["HARNESS_WORKDIR"] ?? ""
        if !override.isEmpty { return override }
        return NSTemporaryDirectory() + "ai.garime.whisper"
    }()

    static let streamingEnabled = true
    static let streamSampleRate: Double = 16000
    static let stepSeconds: TimeInterval = 1.5
    static let windowBackoffSeconds: Double = 1.0
    static let minWindowSeconds: Double = 1.0
    static let commitMarginSeconds: Double = 0.5
    static let uncommittedGiveUpSeconds: Double = 30.0
    static let agreementSteps = 2
    static let maxStepFailures = 2
    static let stepTimeout: TimeInterval = 25
    static let flushTimeout: TimeInterval = 60
    static let promptTailCharacters = 200
    static let overlapDedupWords = 6
    static let typistChunkUTF16 = 20

    static let flushMinNgram = 3
    static let flushMaxNgram = 5
    static let flushMaxNgramRepeats = 3
    static let flushMaxWordsPerSecond: Double = 4.0
    static let flushWordSlack = 8
    static let flushMaxTailWords = 100

    static let seamSilenceGapSeconds: Double = 0.01
    static let seamFragmentMaxSeconds: Double = 0.25
    static let seamOnsetToleranceSeconds: Double = 0.05
    static let seamSnapSlackSeconds: Double = 0.6
    static let seamBoundaryRetentionSeconds: Double = 8.0
    static let seamMaxRetainedBoundaries = 64

    static let streamChunkSamples = 8192

    static let meterAttack: Float = 0.65
    static let meterRelease: Float = 0.2
    static let meterFloorDecibels: Float = -55
    static let meterPeakHoldSeconds: Double = 0.3
    static let meterBarCount = 5

    static let iconPulseFrames = 8
    static let iconPulseInterval: TimeInterval = 0.05
    static let iconSpinnerFrames = 12
    static let iconSpinnerInterval: TimeInterval = 0.08
    static let iconCancelledSeconds: TimeInterval = 0.25
    static let iconLevelInterval: TimeInterval = 0.06
    static let iconReducedLevelInterval: TimeInterval = 0.33
    static let iconReducedBlinkInterval: TimeInterval = 1.0
    static let iconFlashSeconds: TimeInterval = 0.6
}

enum Preflight {
    static func missingDependency() -> String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: Config.ffmpegBinary) {
            return "ffmpeg ausente em \(Config.ffmpegBinary)"
        }
        if !fm.isExecutableFile(atPath: Config.whisperBinary) {
            return "whisper-cli ausente em \(Config.whisperBinary)"
        }
        if !fm.isReadableFile(atPath: Config.modelPath) {
            return "modelo ausente em \(Config.modelPath)"
        }
        return nil
    }
}
