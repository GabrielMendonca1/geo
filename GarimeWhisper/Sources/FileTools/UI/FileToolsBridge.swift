import Foundation

final class FileToolsBridge: FilesRunning {
    private let backend = FileToolsBackend()
    private var capabilityCache: [String: FilesCapability] = [:]
    private let cacheLock = NSLock()

    func capability(for url: URL) -> FilesCapability {
        let key = url.path
        cacheLock.lock()
        if let cached = capabilityCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let reported = backend.capabilities(for: url)
        let capability = FilesCapability(
            kinds: Set(reported.operations.map { FileToolsBridge.name(of: $0) }),
            formats: Set(reported.conversionTargets.map(\.rawValue))
        )
        cacheLock.lock()
        capabilityCache[key] = capability
        cacheLock.unlock()
        return capability
    }

    func batchKinds(for urls: [URL]) -> Set<String>? {
        guard urls.count > 1 else { return [] }
        return Set(backend.batchCapabilities(for: urls).operations.map(\.rawValue))
    }

    func run(
        input: URL,
        option: FilesOption,
        values: [String: FilesValue],
        outputDirectory: URL?
    ) async throws -> FilesOutcome {
        try await perform(inputs: [input], option: option, values: values, outputDirectory: outputDirectory)
    }

    func runBatch(
        inputs: [URL],
        option: FilesOption,
        values: [String: FilesValue],
        outputDirectory: URL?
    ) async throws -> FilesOutcome {
        guard inputs.count > 1 else {
            throw FilesUIError.batchNeedsMoreInputs(option.title)
        }
        return try await perform(inputs: inputs, option: option, values: values, outputDirectory: outputDirectory)
    }

    private func perform(
        inputs: [URL],
        option: FilesOption,
        values: [String: FilesValue],
        outputDirectory: URL?
    ) async throws -> FilesOutcome {
        let operation = try FileToolsBridge.operation(option: option, values: values)
        let request = FileToolsRequest(
            inputURLs: inputs,
            operation: operation,
            outputDirectory: outputDirectory,
            timeout: 600,
            maximumOutputBytes: 2 * 1024 * 1024 * 1024
        )
        let result = try await backend.perform(request)
        return FilesOutcome(outputs: result.outputURLs, message: result.message)
    }

    static func name(of kind: FileToolsOperationKind) -> String { kind.rawValue }

    static func name(of kind: Any) -> String {
        let described = String(describing: kind)
        if let paren = described.firstIndex(of: "(") { return String(described[..<paren]) }
        return described
    }

    private static func int(_ values: [String: FilesValue], _ key: String, _ fallback: Int) -> Int {
        values[key]?.number.map { Int($0.rounded()) } ?? fallback
    }

    private static func double(_ values: [String: FilesValue], _ key: String, _ fallback: Double) -> Double {
        values[key]?.number ?? fallback
    }

    private static func text(_ values: [String: FilesValue], _ key: String, _ fallback: String) -> String {
        values[key]?.string ?? fallback
    }

    static func operation(option: FilesOption, values: [String: FilesValue]) throws -> FileToolsOperation {
        switch option.kind {
        case "convert":
            guard let raw = option.format, let format = FileToolsFormat(rawValue: raw) else {
                throw FilesUIError.unknownFormat(option.format ?? "?")
            }
            return .convert(to: format)
        case "compress":
            return .compress(quality: int(values, "quality", 75))
        case "removeMetadata":
            return .removeMetadata
        case "crop":
            return .crop(
                x: int(values, "x", 0),
                y: int(values, "y", 0),
                width: int(values, "width", 0),
                height: int(values, "height", 0)
            )
        case "scanQRCode":
            return .scanQRCode
        case "mute":
            return .mute
        case "trim":
            return .trim(start: double(values, "start", 0), duration: double(values, "duration", 0))
        case "speed":
            return .speed(double(values, "speed", 1))
        case "snapshot":
            return .snapshot(time: double(values, "time", 0))
        case "split":
            return .split(segmentDuration: double(values, "segment", 60))
        case "normalize":
            return .normalize
        case "channels":
            return .channels(int(values, "channels", 1))
        case "extract":
            return .extract
        case "merge":
            guard let raw = option.format, let format = FileToolsFormat(rawValue: raw) else {
                throw FilesUIError.unknownFormat(option.format ?? "?")
            }
            return .merge(to: format)
        case "collage":
            guard let raw = option.format, let format = FileToolsFormat(rawValue: raw) else {
                throw FilesUIError.unknownFormat(option.format ?? "?")
            }
            let layout = FileToolsCollageLayout(rawValue: text(values, "layout", "grid")) ?? .grid
            let options = FileToolsCollageOptions(
                layout: layout,
                canvasWidth: int(values, "width", 2_400),
                columns: layout == .grid ? int(values, "columns", 2) : nil,
                spacing: int(values, "spacing", 16),
                margin: int(values, "margin", 24),
                backgroundHex: text(values, "background", "#ffffff"),
                fit: text(values, "fit", "contain") == "cover" ? .cover : .contain
            )
            return .collage(options: options, format: format)
        default:
            throw FilesUIError.unknownOperation(option.kind)
        }
    }
}

enum FilesUIError: LocalizedError {
    case unknownFormat(String)
    case unknownOperation(String)
    case batchNeedsMoreInputs(String)
    case batchUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFormat(value): return "formato não suportado: \(value)"
        case let .unknownOperation(value): return "operação não suportada: \(value)"
        case let .batchNeedsMoreInputs(value): return "\(value) precisa de pelo menos 2 arquivos"
        case let .batchUnavailable(value): return "\(value) não está disponível neste motor"
        }
    }
}
