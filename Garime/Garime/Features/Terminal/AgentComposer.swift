import AVFoundation
import Foundation
import Speech

struct AgentCommand: Identifiable, Equatable {
    let name: String
    let description: String
    let scope: String
    var builtin = false

    var id: String { name }
}

struct AgentCommandsPayload: Decodable {
    let agent: String
    let commands: [AgentCommand]

    private struct Raw: Decodable {
        let name: String?
        let description: String?
        let scope: String?
        let builtin: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case agent, commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = ((try? container.decodeIfPresent(String.self, forKey: .agent)) ?? nil) ?? ""
        let raw = ((try? container.decodeIfPresent([Raw].self, forKey: .commands)) ?? nil) ?? []
        commands = raw.compactMap { item in
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return AgentCommand(
                name: name,
                description: item.description ?? "",
                scope: item.scope ?? "",
                builtin: item.builtin ?? false
            )
        }
    }
}

enum AgentCommandMenu {
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(rest)
    }

    static func filter(_ commands: [AgentCommand], query: String) -> [AgentCommand] {
        guard !query.isEmpty else { return commands }
        let needle = query.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(needle) }
    }

    static func inserted(_ name: String) -> String {
        "/\(name) "
    }
}

enum DictationDraft {
    static func merged(base: String, transcript: String) -> String? {
        guard !transcript.isEmpty else { return nil }
        return base.isEmpty ? transcript : base + " " + transcript
    }
}

enum AgentUploadLimit {
    static let maxBytes = 32 * 1024 * 1024

    static func exceeds(_ count: Int) -> Bool { count > maxBytes }
}

enum AgentFileRead {
    enum Outcome: Equatable {
        case ok(Data)
        case tooLarge
        case failed
    }

    static func read(_ url: URL) -> Outcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !AgentUploadLimit.exceeds(size) else { return .tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failed }
        guard !AgentUploadLimit.exceeds(data.count) else { return .tooLarge }
        return .ok(data)
    }
}

enum AgentUploadFailure {
    static func text(_ error: Error) -> String {
        guard case BridgeError.server(let status, _) = error else { return "upload falhou" }
        switch status {
        case 413: return "arquivo grande demais"
        case 503: return "mac fora do ar"
        default: return "upload falhou"
        }
    }
}

@MainActor
final class AgentComposerModel: ObservableObject {
    @Published private(set) var commands: [AgentCommand] = []
    @Published private(set) var uploading = false
    @Published private(set) var notice = ""

    private let client: any BridgeAPI
    private let target: AgentChatTarget
    private var commandsLoaded = false
    private var loadingCommands = false

    init(target: AgentChatTarget, client: any BridgeAPI = BridgeClient.shared) {
        self.target = target
        self.client = client
    }

    func loadCommands() async {
        guard !commandsLoaded, !loadingCommands else { return }
        loadingCommands = true
        commandsLoaded = true
        defer { loadingCommands = false }
        let path = BridgeEndpoint.termAgentCommands(target: target.ref).path
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken),
              let payload = try? JSONDecoder().decode(AgentCommandsPayload.self, from: data) else { return }
        commands = payload.commands
    }

    func upload(_ data: Data, filename: String) async -> String? {
        guard !data.isEmpty else {
            notice = "arquivo vazio"
            return nil
        }
        guard !AgentUploadLimit.exceeds(data.count) else {
            notice = "arquivo grande demais"
            return nil
        }
        uploading = true
        notice = "enviando \(filename)"
        defer { uploading = false }
        let path = BridgeEndpoint.termAgentUpload(target: target.ref).path
        do {
            let response = try await client.uploadFile(
                path,
                body: data,
                filename: filename,
                token: BridgeConfig.termToken
            )
            let result = try JSONDecoder().decode(TermUploadResult.self, from: response)
            notice = ""
            return result.path
        } catch {
            notice = AgentUploadFailure.text(error)
            return nil
        }
    }

    func fail(_ text: String) {
        notice = text
    }

    func clearNotice() {
        guard !uploading else { return }
        notice = ""
    }
}

@MainActor
final class AgentDictationModel: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published private(set) var notice = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
        ?? SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if recording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            notice = "ditado indisponível"
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            notice = "ditado local indisponível"
            return
        }
        transcript = ""
        notice = ""
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized else {
                    self.notice = "sem permissão de transcrição"
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard granted else {
                            self.notice = "sem permissão de microfone"
                            return
                        }
                        self.begin(recognizer)
                    }
                }
            }
        }
    }

    func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text { transcript = text }
        guard failed || isFinal else { return }
        if failed, transcript.isEmpty { notice = "não entendi o áudio" }
        stop()
    }

    func stop() {
        guard recording || request != nil else { return }
        recording = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let buffered = SFSpeechAudioBufferRecognitionRequest()
            buffered.shouldReportPartialResults = true
            buffered.requiresOnDeviceRecognition = true
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                buffered.append(buffer)
            }
            engine.prepare()
            try engine.start()
            request = buffered
            recording = true
            task = recognizer.recognitionTask(with: buffered) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.handle(
                        text: result?.bestTranscription.formattedString,
                        isFinal: result?.isFinal == true,
                        failed: error != nil
                    )
                }
            }
        } catch {
            notice = "não deu pra gravar"
            stop()
        }
    }
}
