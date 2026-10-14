import Foundation

public enum FileToolsFormat: String, CaseIterable, Sendable {
    case png, webp, heic, tiff, pdf, docx
    case mp4, mov, mkv, gif, mp3, m4a
    case wav, flac
    case jpg, txt
    case gzip, rar, tar, zip
}

public enum FileToolsCollageLayout: String, CaseIterable, Sendable, Equatable {
    case grid, row, column, featured, horizontal, vertical
}

public enum FileToolsImageFit: Sendable, Equatable {
    case contain, cover
}

public struct FileToolsCollageOptions: Sendable, Equatable {
    public let layout: FileToolsCollageLayout
    public let canvasWidth: Int
    public let columns: Int?
    public let spacing: Int
    public let margin: Int
    public let backgroundHex: String
    public let fit: FileToolsImageFit

    public init(
        layout: FileToolsCollageLayout = .grid,
        canvasWidth: Int = 2_400,
        columns: Int? = nil,
        spacing: Int = 16,
        margin: Int = 24,
        backgroundHex: String = "#FFFFFF",
        fit: FileToolsImageFit = .contain
    ) {
        self.layout = layout
        self.canvasWidth = canvasWidth
        self.columns = columns
        self.spacing = spacing
        self.margin = margin
        self.backgroundHex = backgroundHex
        self.fit = fit
    }
}

public enum FileToolsBatchOperationKind: String, CaseIterable, Sendable {
    case merge, collage
}

public struct FileToolsBatchCapabilities: Sendable {
    public let operations: [FileToolsBatchOperationKind]

    public init(operations: [FileToolsBatchOperationKind]) {
        self.operations = operations
    }
}

public enum FileToolsBatchOperation: Sendable {
    case merge
    case collage(layout: FileToolsCollageLayout, columns: Int, spacing: Int, background: String)
}

public struct FileToolsBatchRequest: Sendable {
    public let inputURLs: [URL]
    public let operation: FileToolsBatchOperation
    public let outputDirectory: URL?
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int64
    public let maximumInputBytes: Int64
    public let maximumInputCount: Int
    public let maximumPages: Int
    public let maximumImagePixels: Int64

    public init(
        inputURLs: [URL],
        operation: FileToolsBatchOperation,
        outputDirectory: URL? = nil,
        timeout: TimeInterval = 120,
        maximumOutputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputCount: Int = 128,
        maximumPages: Int = 1_000,
        maximumImagePixels: Int64 = 100_000_000
    ) {
        self.inputURLs = inputURLs
        self.operation = operation
        self.outputDirectory = outputDirectory
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumInputBytes = maximumInputBytes
        self.maximumInputCount = maximumInputCount
        self.maximumPages = maximumPages
        self.maximumImagePixels = maximumImagePixels
    }
}

public enum FileToolsOperation: Sendable {
    case convert(to: FileToolsFormat)
    case compress(quality: Int = 75)
    case removeMetadata
    case crop(x: Int, y: Int, width: Int, height: Int)
    case scanQRCode
    case mute
    case trim(start: TimeInterval, duration: TimeInterval)
    case speed(Double)
    case snapshot(time: TimeInterval)
    case split(segmentDuration: TimeInterval)
    case normalize
    case channels(Int)
    case extract
    case collage(options: FileToolsCollageOptions = .init(), format: FileToolsFormat = .png)
    case merge(to: FileToolsFormat)
}

public enum FileToolsOperationKind: String, CaseIterable, Sendable {
    case convert, compress, removeMetadata, crop, scanQRCode, mute, trim, speed
    case snapshot, split, normalize, channels, extract, collage, merge
}

public struct FileToolsRequest: Sendable {
    public let inputURLs: [URL]
    public let inputURL: URL
    public let operation: FileToolsOperation
    public let outputDirectory: URL?
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int64
    public let maximumInputBytes: Int64
    public let maximumInputCount: Int
    public let maximumPages: Int
    public let maximumImagePixels: Int64
    public let maximumArchiveMembers: Int
    public let maximumArchiveDepth: Int
    public let maximumArchivePathBytes: Int

    public init(
        inputURL: URL,
        operation: FileToolsOperation,
        outputDirectory: URL? = nil,
        timeout: TimeInterval = 120,
        maximumOutputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputCount: Int = 128,
        maximumPages: Int = 1_000,
        maximumImagePixels: Int64 = 100_000_000,
        maximumArchiveMembers: Int = 10_000,
        maximumArchiveDepth: Int = 32,
        maximumArchivePathBytes: Int = 1_024
    ) {
        self.init(
            inputURLs: [inputURL], operation: operation, outputDirectory: outputDirectory,
            timeout: timeout, maximumOutputBytes: maximumOutputBytes,
            maximumInputBytes: maximumInputBytes, maximumInputCount: maximumInputCount,
            maximumPages: maximumPages, maximumImagePixels: maximumImagePixels,
            maximumArchiveMembers: maximumArchiveMembers, maximumArchiveDepth: maximumArchiveDepth,
            maximumArchivePathBytes: maximumArchivePathBytes
        )
    }

    public init(
        inputURLs: [URL],
        operation: FileToolsOperation,
        outputDirectory: URL? = nil,
        timeout: TimeInterval = 120,
        maximumOutputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumInputCount: Int = 128,
        maximumPages: Int = 1_000,
        maximumImagePixels: Int64 = 100_000_000,
        maximumArchiveMembers: Int = 10_000,
        maximumArchiveDepth: Int = 32,
        maximumArchivePathBytes: Int = 1_024
    ) {
        self.inputURLs = inputURLs
        self.inputURL = inputURLs.first ?? URL(fileURLWithPath: "/dev/null")
        self.operation = operation
        self.outputDirectory = outputDirectory
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumInputBytes = maximumInputBytes
        self.maximumInputCount = maximumInputCount
        self.maximumPages = maximumPages
        self.maximumImagePixels = maximumImagePixels
        self.maximumArchiveMembers = maximumArchiveMembers
        self.maximumArchiveDepth = maximumArchiveDepth
        self.maximumArchivePathBytes = maximumArchivePathBytes
    }
}

public struct FileToolsCapabilities: Sendable {
    public let operations: [FileToolsOperationKind]
    public let conversionTargets: [FileToolsFormat]

    public init(operations: [FileToolsOperationKind], conversionTargets: [FileToolsFormat]) {
        self.operations = operations
        self.conversionTargets = conversionTargets
    }
}

public struct FileToolsResult: Sendable {
    public let outputURLs: [URL]
    public let message: String?
    public let committed: Bool

    public init(outputURLs: [URL], message: String? = nil, committed: Bool = true) {
        self.outputURLs = outputURLs
        self.message = message
        self.committed = committed
    }
}

public enum FileToolsError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case invalidRequest(String)
    case dependencyMissing(String)
    case processFailed(String)
    case timedOut
    case cancelled
    case outputTooLarge
    case unsafeArchive(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let value): return "Operação não suportada: \(value)"
        case .invalidRequest(let value): return "Pedido inválido: \(value)"
        case .dependencyMissing(let value): return "Dependência ausente: \(value)"
        case .processFailed(let value): return "Falha na conversão: \(value)"
        case .timedOut: return "A operação excedeu o tempo limite"
        case .cancelled: return "A operação foi cancelada"
        case .outputTooLarge: return "A saída excedeu o limite configurado"
        case .unsafeArchive(let value): return "Arquivo inseguro: \(value)"
        }
    }
}
