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
    static let maxWindowSeconds: Double = 12.0
    static let maxStepFailures = 2
    static let stepTimeout: TimeInterval = 25
    static let flushTimeout: TimeInterval = 60
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
    static let iconTriangleInset: CGFloat = 3
    static let iconDotRadius: CGFloat = 1.8
    static let iconSwellFrames = 18
    static let iconSwellInterval: TimeInterval = 0.06
    static let iconRainFrames = 22
    static let iconRainInterval: TimeInterval = 0.075
    static let iconBeatFrames = 24
    static let iconBeatInterval: TimeInterval = 0.07

    static let meetingsDirectory = NSHomeDirectory() + "/Recordings"
    static let meetingLabel = "reuniao"
    static let meetingMinSeconds: TimeInterval = 1.0
    static let meetingConvertTimeout: TimeInterval = 900
    static let meetingTranscribeTimeout: TimeInterval = 3600
    static let meetingElapsedRefresh: TimeInterval = 60

    static let captureRoot = NSHomeDirectory() + "/Library/Application Support/Garime/GarimeCapture"
    static let capturePollInterval: TimeInterval = 5
    static let captureHeartbeatMaxAge: TimeInterval = 300

    static let hubDirectory = NSHomeDirectory() + "/Library/Application Support/Garime/Hub"
    static let sshBinary = "/usr/bin/ssh"
    static let tasksHost = "garime"
    static let tasksRemoteGlob = "/mnt/garime/Vault/Tasks/" + "*.json"
    static let tasksFetchTimeout: TimeInterval = 20
    static let tasksRefreshInterval: TimeInterval = 300
    static let tasksStaleAfter: TimeInterval = 120
    static let tasksMenuLimit = 15
    static let taskTitleLimit = 58
    static let panelWidth: CGFloat = 380
    static let panelInset: CGFloat = 20
    static let panelTopPad: CGFloat = 18
    static let panelBottomPad: CGFloat = 18
    static let panelSectionGap: CGFloat = 20
    static let panelHeaderGap: CGFloat = 20
    static let panelRowHeight: CGFloat = 34
    static let panelGlyphX: CGFloat = 30
    static let panelTextX: CGFloat = 54
    static let panelCornerRadius: CGFloat = 14
    static let panelActionSize: CGFloat = 34
    static let panelFadeSeconds: TimeInterval = 0.16
    static let panelSlideRise: CGFloat = 10
    static let panelYieldSeconds: TimeInterval = 0.18
    static let panelTodoLimit = 12
    static let panelListLimit = 200
    static let capsPollSeconds: TimeInterval = 1.0
    static let panelMaxBodyHeight: CGFloat = 420
    static let vaultDirectory = NSHomeDirectory() + "/Vault"
    static let panelGap: CGFloat = 6
    static let panelProjectLimit = 6

    static let projectRoots = [
        NSHomeDirectory() + "/Garime",
        NSHomeDirectory() + "/Omni",
        NSHomeDirectory() + "/ARCA",
        NSHomeDirectory() + "/Lab",
        NSHomeDirectory() + "/.claude",
    ]
    static let projectTodoLimit = 10

    static let recScript = NSHomeDirectory() + "/Garime/brain/skills/record/scripts/rec.sh"
    static let recStatePath = NSHomeDirectory() + "/.cache/whisper/rec.state"
    static let recPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let callPollInterval: TimeInterval = 5
    static let callStartTimeout: TimeInterval = 30
    static let callStopTimeout: TimeInterval = 3600
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
