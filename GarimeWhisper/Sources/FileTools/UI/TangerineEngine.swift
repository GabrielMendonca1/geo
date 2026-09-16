import Foundation

protocol TangerineRunning: AnyObject {
    func capability(for url: URL) -> TangerineCapability

    func batchKinds(for urls: [URL]) -> Set<String>?

    func run(
        input: URL,
        option: TangerineOption,
        values: [String: TangerineValue],
        outputDirectory: URL?
    ) async throws -> TangerineOutcome

    func runBatch(
        inputs: [URL],
        option: TangerineOption,
        values: [String: TangerineValue],
        outputDirectory: URL?
    ) async throws -> TangerineOutcome
}

extension TangerineRunning {
    func batchKinds(for urls: [URL]) -> Set<String>? { nil }

    func runBatch(
        inputs: [URL],
        option: TangerineOption,
        values: [String: TangerineValue],
        outputDirectory: URL?
    ) async throws -> TangerineOutcome {
        throw TangerineUIError.batchUnavailable(option.title)
    }
}

struct TangerineOutcome {
    let outputs: [URL]
    let message: String?
}

enum TangerineJobState: Equatable {
    case running
    case done
    case failed
    case cancelled
}

final class TangerineJob {
    let id = UUID()
    let inputs: [URL]
    let option: TangerineOption
    let values: [String: TangerineValue]
    let startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var state: TangerineJobState = .running
    private(set) var cancelRequested = false
    private(set) var outputs: [URL] = []
    private(set) var message: String?
    var task: Task<Void, Never>?

    init(inputs: [URL], option: TangerineOption, values: [String: TangerineValue]) {
        self.inputs = inputs
        self.option = option
        self.values = values
    }

    convenience init(input: URL, option: TangerineOption, values: [String: TangerineValue]) {
        self.init(inputs: [input], option: option, values: values)
    }

    var input: URL { inputs[0] }

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    var title: String {
        if inputs.count > 1 {
            return "\(option.title) · \(inputs.count) arquivos"
        }
        return "\(option.title) · \(input.lastPathComponent)"
    }

    var subtitle: String {
        switch state {
        case .running:
            if cancelRequested { return String(format: "cancelando… %.0fs", elapsed) }
            return String(format: "processando… %.0fs", elapsed)
        case .done:
            if let message, !message.isEmpty { return message }
            if outputs.count > 1 { return "\(outputs.count) arquivos em \(elapsed.formattedShort)" }
            return (outputs.first?.lastPathComponent ?? "concluído") + " · " + elapsed.formattedShort
        case .failed:
            return message ?? "falhou"
        case .cancelled:
            return "cancelado"
        }
    }

    func finish(outputs: [URL], message: String?) {
        self.outputs = outputs
        self.message = message
        state = .done
        finishedAt = Date()
    }

    func requestCancel() {
        cancelRequested = true
    }

    func fail(_ reason: String) {
        message = reason
        state = .failed
        finishedAt = Date()
    }

    func markCancelled() {
        state = .cancelled
        finishedAt = Date()
    }
}

extension TimeInterval {
    var formattedShort: String {
        self < 60 ? String(format: "%.1fs", self) : String(format: "%dm%02ds", Int(self) / 60, Int(self) % 60)
    }
}

final class TangerineJobCenter {
    static var playCompletedFeedback: (() -> Void)?
    static var playCancelledFeedback: (() -> Void)?
    static var playErrorFeedback: (() -> Void)?

    private(set) var jobs: [TangerineJob] = []
    private let engine: TangerineRunning
    private let historyLimit = 30
    private var observers: [(id: String, block: () -> Void)] = []

    func addObserver(_ id: String, _ block: @escaping () -> Void) {
        observers.removeAll { $0.id == id }
        observers.append((id, block))
    }

    init(engine: TangerineRunning) {
        self.engine = engine
    }

    var hasRunning: Bool { jobs.contains { $0.state == .running } }

    func capability(for url: URL) -> TangerineCapability {
        engine.capability(for: url)
    }

    func capability(for urls: [URL]) -> TangerineCapability {
        let perFile = TangerineCapability.intersection(urls.map { engine.capability(for: $0) })
        guard let batch = engine.batchKinds(for: urls) else { return perFile }
        return perFile.withBatchKinds(batch)
    }

    func rejects(option: TangerineOption, inputs: [URL]) -> [URL] {
        if option.isBatch {
            guard let batch = engine.batchKinds(for: inputs) else { return [] }
            return batch.contains(option.kind) ? [] : inputs
        }
        return inputs.filter { !engine.capability(for: $0).allows(option) }
    }

    func blocker(option: TangerineOption, inputs: [URL]) -> String? {
        guard !inputs.isEmpty else { return "Escolha ao menos um arquivo." }
        if option.isBatch, inputs.count < 2 {
            return "\(option.title) precisa de pelo menos 2 arquivos."
        }
        let rejected = rejects(option: option, inputs: inputs)
        guard !rejected.isEmpty else { return nil }
        if option.isBatch {
            return "\(option.title) não serve a esta seleção de \(inputs.count) arquivos."
        }
        let names = rejected.prefix(2).map { $0.lastPathComponent }.joined(separator: ", ")
        let extra = rejected.count > 2 ? " +\(rejected.count - 2)" : ""
        return "\(option.title) não serve a \(names)\(extra)."
    }

    @discardableResult
    func submit(
        inputs: [URL],
        option: TangerineOption,
        values: [String: TangerineValue],
        outputDirectory: URL? = nil
    ) -> [TangerineJob] {
        guard !inputs.isEmpty else { return [] }
        let created: [TangerineJob] = option.isBatch
            ? [TangerineJob(inputs: inputs, option: option, values: values)]
            : inputs.map { TangerineJob(input: $0, option: option, values: values) }
        for job in created { start(job, outputDirectory: outputDirectory) }
        jobs.insert(contentsOf: created, at: 0)
        trim()
        notify()
        return created
    }

    private func start(_ job: TangerineJob, outputDirectory: URL?) {
        let engine = self.engine
        job.task = Task { [weak self] in
            do {
                let outcome: TangerineOutcome
                if job.option.isBatch {
                    outcome = try await engine.runBatch(
                        inputs: job.inputs,
                        option: job.option,
                        values: job.values,
                        outputDirectory: outputDirectory
                    )
                } else {
                    outcome = try await engine.run(
                        input: job.input,
                        option: job.option,
                        values: job.values,
                        outputDirectory: outputDirectory
                    )
                }
                let interrupted = Task.isCancelled
                await MainActor.run { [weak self] in
                    if interrupted, outcome.outputs.isEmpty {
                        job.markCancelled()
                        TangerineJobCenter.playCancelledFeedback?()
                    } else {
                        job.finish(outputs: outcome.outputs, message: outcome.message)
                        TangerineJobCenter.playCompletedFeedback?()
                    }
                    self?.notify()
                }
            } catch {
                let cancelled = (error is CancellationError) || Task.isCancelled
                    || String(describing: error).lowercased().contains("cancel")
                await MainActor.run { [weak self] in
                    if cancelled {
                        job.markCancelled()
                        TangerineJobCenter.playCancelledFeedback?()
                    } else {
                        job.fail(TangerineJobCenter.describe(error))
                        TangerineJobCenter.playErrorFeedback?()
                    }
                    self?.notify()
                }
            }
        }
    }

    func cancel(_ job: TangerineJob) {
        guard job.state == .running else { return }
        job.requestCancel()
        job.task?.cancel()
        notify()
    }

    func cancelAll() {
        for job in jobs where job.state == .running {
            job.requestCancel()
            job.task?.cancel()
        }
        notify()
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
        notify()
    }

    private func trim() {
        guard jobs.count > historyLimit else { return }
        var kept: [TangerineJob] = []
        for job in jobs where kept.count < historyLimit || job.state == .running {
            kept.append(job)
        }
        jobs = kept
    }

    func notify() {
        for observer in observers { observer.block() }
    }

    static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let described = String(describing: error)
        if let readable = readableBackendError(described) { return readable }
        let localized = error.localizedDescription
        return localized.isEmpty ? described : localized
    }

    private static func readableBackendError(_ described: String) -> String? {
        let table: [(String, String)] = [
            ("dependencyMissing", "ferramenta ausente"),
            ("unsupported", "operação não suportada para este arquivo"),
            ("invalidRequest", "parâmetros inválidos"),
            ("processFailed", "o conversor falhou"),
            ("timedOut", "tempo esgotado"),
            ("outputTooLarge", "saída grande demais"),
            ("unsafeArchive", "arquivo compactado inseguro"),
            ("cancelled", "cancelado"),
        ]
        for (needle, text) in table where described.contains(needle) {
            guard let detail = payload(of: needle, in: described), detail.count <= 120 else { return text }
            return "\(text): \(detail)"
        }
        return nil
    }

    private static func payload(of needle: String, in text: String) -> String? {
        guard let open = text.range(of: needle + "(") else { return nil }
        let rest = text[open.upperBound...]
        let close = rest.range(of: "\")") ?? rest.range(of: ")")
        guard let close else { return nil }
        let candidate = rest[..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return candidate.isEmpty ? nil : candidate
    }
}
