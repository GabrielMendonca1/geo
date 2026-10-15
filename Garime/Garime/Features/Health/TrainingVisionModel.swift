import Foundation

@MainActor
final class TrainingVisionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading
        case waiting
        case done(TrainingVisionReading)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Quanto tempo esperamos o agente olhar a foto antes de desistir.
    static let timeout: TimeInterval = 120
    static let pollInterval: UInt64 = 2_000_000_000

    private let composer: AgentComposerModel
    private let chat: AgentChatModel
    private let clock: () -> Date

    init(
        target: AgentChatTarget,
        client: any BridgeAPI = BridgeClient.shared,
        clock: @escaping () -> Date = Date.init
    ) {
        self.composer = AgentComposerModel(target: target, client: client)
        self.chat = AgentChatModel(target: target, client: client)
        self.clock = clock
    }

    func reset() {
        phase = .idle
    }

    func analyze(image: Data, exercise: String, now: Date? = nil) async {
        phase = .uploading
        let filename = "treino-\(Self.stamp(now ?? clock())).jpg"

        guard let path = await composer.upload(image, filename: filename) else {
            phase = .failed(composer.notice.isEmpty ? "não deu pra enviar a foto" : composer.notice)
            return
        }

        let nonce = TrainingVisionPrompt.nonce()
        phase = .waiting
        await chat.send(TrainingVisionPrompt.text(imagePath: path, exercise: exercise, nonce: nonce))

        let deadline = clock().addingTimeInterval(Self.timeout)
        while clock() < deadline {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled { return }
            await chat.refresh()
            if let reading = TrainingVisionReply.parse(messages: chat.messages, nonce: nonce) {
                phase = .done(reading)
                return
            }
        }
        phase = .failed("o agente não respondeu a tempo")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
