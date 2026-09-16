import Foundation

enum TangerineCategory: String, CaseIterable {
    case images
    case video
    case audio
    case documents
    case archives

    var title: String {
        switch self {
        case .images: return "Imagens"
        case .video: return "Vídeo"
        case .audio: return "Áudio"
        case .documents: return "Documentos"
        case .archives: return "Arquivos"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        }
    }

    static func of(_ url: URL) -> TangerineCategory? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "tif", "gif", "bmp", "svg":
            return .images
        case "mp4", "mov", "mkv", "m4v", "avi", "webm":
            return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "aif", "caf":
            return .audio
        case "pdf", "txt", "md", "docx", "rtf":
            return .documents
        case "zip", "tar", "gz", "tgz", "gzip", "rar", "7z", "bz2", "xz":
            return .archives
        default:
            return nil
        }
    }
}

enum TangerineValue: Equatable {
    case number(Double)
    case text(String)

    var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }
}

struct TangerineChoice: Equatable {
    let value: String
    let label: String
}

struct TangerineParam: Equatable {
    enum Kind: Equatable {
        case seconds
        case integer(min: Int, max: Int)
        case decimal(min: Double, max: Double)
        case choice([TangerineChoice])
        case color
    }

    let id: String
    let label: String
    let kind: Kind
    let fallback: String
    let hint: String

    enum Parsed: Equatable {
        case value(TangerineValue)
        case problem(String)

        static func value(_ number: Double) -> Parsed { .value(.number(number)) }
    }

    var choices: [TangerineChoice] {
        if case let .choice(options) = kind { return options }
        return []
    }

    var isTextual: Bool {
        switch kind {
        case .choice, .color: return true
        case .seconds, .integer, .decimal: return false
        }
    }

    func parse(_ raw: String) -> Parsed {
        switch kind {
        case let .choice(options):
            return parseChoice(raw, options: options)
        case .color:
            return parseColor(raw)
        case .seconds, .integer, .decimal:
            return parseNumber(raw)
        }
    }

    private func parseChoice(_ raw: String, options: [TangerineChoice]) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return .problem("\(label): vazio") }
        if let hit = options.first(where: { $0.value.lowercased() == text || $0.label.lowercased() == text }) {
            return .value(.text(hit.value))
        }
        return .problem("\(label): use \(options.map(\.value).joined(separator: ", "))")
    }

    private func parseColor(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return .problem("\(label): vazio") }
        if text == "transparent" || text == "transparente" { return .value(.text("transparent")) }
        var digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if digits.count == 3, digits.allSatisfy({ $0.isHexDigit }) {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else {
            return .problem("\(label): use #rrggbb ou transparent")
        }
        return .value(.text("#\(digits)"))
    }

    private func parseNumber(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return .problem("\(label): vazio") }
        if case .seconds = kind, text.contains(":") {
            let parts = text.split(separator: ":").map(String.init)
            var total: Double = 0
            for part in parts {
                guard let value = Double(part) else { return .problem("\(label): tempo inválido") }
                total = total * 60 + value
            }
            guard total.isFinite else { return .problem("\(label): tempo inválido") }
            return total >= 0 ? .value(total) : .problem("\(label): negativo")
        }
        guard let value = Double(text), value.isFinite else { return .problem("\(label): número inválido") }
        switch kind {
        case .seconds:
            return value >= 0 ? .value(value) : .problem("\(label): negativo")
        case let .integer(min, max):
            let rounded = value.rounded()
            guard rounded >= Double(min), rounded <= Double(max) else {
                return .problem("\(label): fora de \(min)–\(max)")
            }
            return .value(rounded)
        case let .decimal(min, max):
            guard value >= min, value <= max else {
                return .problem("\(label): fora de \(min)–\(max)")
            }
            return .value(value)
        case .choice, .color:
            return .problem("\(label): valor inválido")
        }
    }
}

enum TangerineArity: Equatable {
    case perFile
    case batch
}

struct TangerineOption: Equatable {
    let kind: String

    let format: String?
    let title: String
    let detail: String
    let params: [TangerineParam]
    let arity: TangerineArity

    var id: String { format.map { "\(kind):\($0)" } ?? kind }
    var needsParams: Bool { !params.isEmpty }
    var isBatch: Bool { arity == .batch }

    init(
        kind: String,
        format: String? = nil,
        title: String,
        detail: String = "",
        params: [TangerineParam] = [],
        arity: TangerineArity = .perFile
    ) {
        self.kind = kind
        self.format = format
        self.title = title
        self.detail = detail
        self.params = params
        self.arity = arity
    }
}

struct TangerineGroup: Equatable {
    let title: String
    let options: [TangerineOption]
}

enum TangerineMode: Equatable {
    case convert
    case tools

    var title: String { self == .convert ? "Converter" : "Ferramentas" }
}

struct TangerineCapability: Equatable {
    let known: Bool
    let kinds: Set<String>
    let formats: Set<String>
    let batchKinds: Set<String>

    static let unknown = TangerineCapability(known: false, kinds: [], formats: [], batchKinds: [])

    private init(known: Bool, kinds: Set<String>, formats: Set<String>, batchKinds: Set<String>) {
        self.known = known
        self.kinds = kinds
        self.formats = formats
        self.batchKinds = batchKinds
    }

    init(kinds: Set<String>, formats: Set<String>, batchKinds: Set<String> = []) {
        self.init(known: true, kinds: kinds, formats: formats, batchKinds: batchKinds)
    }

    var isBarren: Bool { known && kinds.isEmpty && batchKinds.isEmpty }

    func withBatchKinds(_ next: Set<String>) -> TangerineCapability {
        TangerineCapability(known: known, kinds: kinds, formats: formats, batchKinds: next)
    }

    func allows(_ option: TangerineOption) -> Bool {
        guard known else { return true }
        if option.isBatch { return batchKinds.contains(option.kind) }
        guard kinds.contains(option.kind) else { return false }
        guard option.kind == "convert" else { return true }
        guard let format = option.format else { return false }
        return formats.contains(format)
    }

    func intersection(_ other: TangerineCapability) -> TangerineCapability {
        guard known else { return other }
        guard other.known else { return self }
        return TangerineCapability(
            kinds: kinds.intersection(other.kinds),
            formats: formats.intersection(other.formats),
            batchKinds: batchKinds.intersection(other.batchKinds)
        )
    }

    static func intersection(_ capabilities: [TangerineCapability]) -> TangerineCapability {
        capabilities.reduce(.unknown) { $0.intersection($1) }
    }
}

enum TangerineCatalog {
    static let convertTargets: [TangerineCategory: [String]] = [
        .images: ["png", "jpg", "webp", "heic", "tiff", "pdf"],
        .video: ["mp4", "mov", "mkv", "gif", "mp3", "m4a"],
        .audio: ["wav", "flac", "m4a", "mp3", "mp4"],
        .documents: ["txt", "png", "jpg"],
        .archives: [],
    ]

    static let animatedImageTargets = ["mp4", "mov", "mkv"]

    static let packageTargets = ["tar", "zip", "gzip"]

    static let formatOrder = [
        "png", "jpg", "webp", "heic", "tiff", "gif",
        "mp4", "mov", "mkv", "mp3", "m4a", "wav", "flac",
        "pdf", "txt", "docx",
        "tar", "zip", "gzip", "rar",
    ]

    private static let documentFormats: Set<String> = ["pdf", "txt", "docx"]
    private static let packageFormats: Set<String> = ["tar", "zip", "gzip", "rar"]

    static let formatDetail: [String: String] = [
        "png": "sem perdas",
        "jpg": "foto compacta",
        "webp": "web moderno",
        "heic": "Apple",
        "tiff": "arquivo mestre",
        "pdf": "documento",
        "docx": "Word",
        "mp4": "H.264",
        "mov": "QuickTime",
        "mkv": "container",
        "gif": "animado",
        "mp3": "áudio",
        "m4a": "áudio AAC",
        "wav": "PCM",
        "flac": "sem perdas",
        "txt": "texto puro",
        "tar": "pacote",
        "zip": "compactado",
        "gzip": "comprimido",
        "rar": "RAR",
    ]

    private static let quality = TangerineParam(
        id: "quality",
        label: "Qualidade",
        kind: .integer(min: 1, max: 100),
        fallback: "75",
        hint: "1–100"
    )

    private static func toolOptions(for category: TangerineCategory) -> [TangerineGroup] {
        let cropParams = [
            TangerineParam(id: "x", label: "X", kind: .integer(min: 0, max: 100_000), fallback: "0", hint: "px"),
            TangerineParam(id: "y", label: "Y", kind: .integer(min: 0, max: 100_000), fallback: "0", hint: "px"),
            TangerineParam(id: "width", label: "Largura", kind: .integer(min: 1, max: 100_000), fallback: "1000", hint: "px"),
            TangerineParam(id: "height", label: "Altura", kind: .integer(min: 1, max: 100_000), fallback: "1000", hint: "px"),
        ]
        let trimParams = [
            TangerineParam(id: "start", label: "Início", kind: .seconds, fallback: "0", hint: "s ou mm:ss"),
            TangerineParam(id: "duration", label: "Duração", kind: .seconds, fallback: "10", hint: "s ou mm:ss"),
        ]
        let speedParam = [
            TangerineParam(id: "speed", label: "Velocidade", kind: .decimal(min: 0.25, max: 4), fallback: "1.5", hint: "0.25–4×"),
        ]
        let snapshotParam = [
            TangerineParam(id: "time", label: "Instante", kind: .seconds, fallback: "1", hint: "s ou mm:ss"),
        ]
        let splitParam = [
            TangerineParam(id: "segment", label: "Trecho", kind: .seconds, fallback: "60", hint: "segundos"),
        ]
        let channelsParam = [
            TangerineParam(id: "channels", label: "Canais", kind: .integer(min: 1, max: 8), fallback: "1", hint: "1 = mono"),
        ]

        let compress = TangerineOption(kind: "compress", title: "Comprimir", detail: "qualidade", params: [quality])

        let clean = TangerineOption(kind: "removeMetadata", title: "Metadados", detail: "EXIF fora")
        let crop = TangerineOption(kind: "crop", title: "Recortar", detail: "retângulo", params: cropParams)
        let qr = TangerineOption(kind: "scanQRCode", title: "Ler QR Code", detail: "texto")
        let trim = TangerineOption(kind: "trim", title: "Cortar", detail: "início/duração", params: trimParams)
        let mute = TangerineOption(kind: "mute", title: "Sem áudio", detail: "faixa muda")
        let speed = TangerineOption(kind: "speed", title: "Velocidade", detail: "ritmo", params: speedParam)

        let snapshot = TangerineOption(kind: "snapshot", title: "Quadro", detail: snapshotFormatLabel, params: snapshotParam)
        let split = TangerineOption(kind: "split", title: "Dividir", detail: "em trechos", params: splitParam)
        let normalize = TangerineOption(kind: "normalize", title: "Normalizar", detail: "loudness")
        let channels = TangerineOption(kind: "channels", title: "Canais", detail: "mono/estéreo", params: channelsParam)
        let extract = TangerineOption(kind: "extract", title: "Extrair", detail: "descompactar")

        switch category {
        case .images:
            return [
                TangerineGroup(title: "Tamanho", options: [compress, crop]),
                TangerineGroup(title: "Conteúdo", options: [clean, qr]),
            ]
        case .video:
            return [
                TangerineGroup(title: "Tempo", options: [trim, split, speed, snapshot]),
                TangerineGroup(title: "Faixa", options: [compress, mute, crop, clean]),
            ]
        case .audio:

            return [
                TangerineGroup(title: "Tempo", options: [trim, split]),
                TangerineGroup(title: "Som", options: [normalize, channels, compress, clean]),
            ]
        case .documents:

            let pages = TangerineOption(kind: "split", title: "Páginas", detail: "1 por página")
            return [
                TangerineGroup(title: "Tamanho", options: [compress, pages]),
                TangerineGroup(title: "Conteúdo", options: [clean, qr]),
            ]
        case .archives:

            return [
                TangerineGroup(title: "Conteúdo", options: [extract]),
            ]
        }
    }

    static func convertGroups(
        category: TangerineCategory,
        sourceExtension: String,
        capability: TangerineCapability = .unknown
    ) -> [TangerineGroup] {
        let source = normalize(sourceExtension)
        var targets: [String]
        if capability.known {
            if capability.kinds.contains("convert") {
                let ordered = formatOrder.filter { capability.formats.contains($0) }
                let extras = capability.formats.subtracting(formatOrder).sorted()
                targets = ordered + extras
            } else {
                targets = []
            }
        } else {
            var fallback = convertTargets[category] ?? []
            if category == .documents, !source.isEmpty, source != "pdf" { fallback = [] }
            if category == .images, source == "gif" { fallback += animatedImageTargets }
            targets = fallback + packageTargets
        }
        targets = targets.filter { $0 != source }
        var groups: [TangerineGroup] = []
        let mediaTargets = targets.filter { !documentFormats.contains($0) && !packageFormats.contains($0) }
        let docs = targets.filter { documentFormats.contains($0) }
        let package = targets.filter { packageFormats.contains($0) }
        if !mediaTargets.isEmpty {
            groups.append(TangerineGroup(title: "Mídia", options: mediaTargets.map(option(format:))))
        }
        if !docs.isEmpty {
            groups.append(TangerineGroup(title: "Documento", options: docs.map(option(format:))))
        }
        if !package.isEmpty {
            groups.append(TangerineGroup(title: "Pacote", options: package.map(option(format:))))
        }
        return groups
    }

    static func toolGroups(category: TangerineCategory, capability: TangerineCapability = .unknown) -> [TangerineGroup] {
        filter(toolOptions(for: category), capability: capability)
    }


    static let mergeTargets: [TangerineCategory: [String]] = [
        .images: ["pdf"],
        .documents: ["pdf"],
        .video: ["mp4", "mkv"],
        .audio: ["m4a", "mp3", "wav", "flac"],
        .archives: [],
    ]

    static let collageTargets = ["png", "jpg", "pdf"]

    static let collageParams: [TangerineParam] = [
        TangerineParam(
            id: "layout",
            label: "Arranjo",
            kind: .choice([
                TangerineChoice(value: "grid", label: "grade"),
                TangerineChoice(value: "row", label: "linha"),
                TangerineChoice(value: "column", label: "coluna"),
                TangerineChoice(value: "featured", label: "destaque"),
            ]),
            fallback: "grid",
            hint: "grade/linha/coluna/destaque"
        ),
        TangerineParam(id: "columns", label: "Colunas", kind: .integer(min: 1, max: 64), fallback: "2", hint: "≤ nº de imagens"),
        TangerineParam(id: "spacing", label: "Espaço", kind: .integer(min: 0, max: 512), fallback: "16", hint: "px entre fotos"),
        TangerineParam(id: "margin", label: "Margem", kind: .integer(min: 0, max: 512), fallback: "24", hint: "px na borda"),
        TangerineParam(id: "width", label: "Largura", kind: .integer(min: 320, max: 16_384), fallback: "2400", hint: "px da tela"),
        TangerineParam(
            id: "fit",
            label: "Ajuste",
            kind: .choice([
                TangerineChoice(value: "contain", label: "conter"),
                TangerineChoice(value: "cover", label: "cobrir"),
            ]),
            fallback: "contain",
            hint: "conter/cobrir"
        ),
        TangerineParam(id: "background", label: "Fundo", kind: .color, fallback: "#ffffff", hint: "#rrggbb/transparent"),
    ]

    static func mergeOption(format: String) -> TangerineOption {
        TangerineOption(
            kind: "merge",
            format: format,
            title: "Juntar \(format.uppercased())",
            detail: "na ordem da lista",
            arity: .batch
        )
    }

    static func collageOption(format: String) -> TangerineOption {
        TangerineOption(
            kind: "collage",
            format: format,
            title: "Colagem \(format.uppercased())",
            detail: "uma imagem só",
            params: collageParams,
            arity: .batch
        )
    }

    static func batchProblem(
        option: TangerineOption,
        values: [String: TangerineValue],
        inputCount: Int
    ) -> String? {
        guard option.kind == "collage" else { return nil }
        let layout = values["layout"]?.string ?? "grid"
        if layout == "grid" {
            let columns = Int(values["columns"]?.number ?? 2)
            guard columns >= 1, columns <= inputCount else {
                return "Colunas: use de 1 a \(inputCount) (uma por imagem)."
            }
        }
        let width = Int(values["width"]?.number ?? 2_400)
        let margin = Int(values["margin"]?.number ?? 24)
        guard margin * 2 < width else {
            return "Margem: deixe menos de \(width / 2) px para caber na largura."
        }
        return nil
    }

    static func batchGroups(
        category: TangerineCategory,
        inputCount: Int,
        capability: TangerineCapability
    ) -> [TangerineGroup] {
        guard inputCount >= 2 else { return [] }
        var options: [TangerineOption] = []
        for format in mergeTargets[category] ?? [] {
            let option = mergeOption(format: format)
            if capability.allows(option) { options.append(option) }
        }
        if category == .images {
            for format in collageTargets {
                let option = collageOption(format: format)
                if capability.allows(option) { options.append(option) }
            }
        }
        return options.isEmpty ? [] : [TangerineGroup(title: "Combinar", options: options)]
    }

    static let snapshotFormatLabel = "PNG"

    private static func option(format: String) -> TangerineOption {
        TangerineOption(
            kind: "convert",
            format: format,
            title: format.uppercased(),
            detail: formatDetail[format] ?? ""
        )
    }

    static func normalize(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "gz", "tgz": return "gzip"
        default: return ext.lowercased()
        }
    }

    static func filter(_ groups: [TangerineGroup], capability: TangerineCapability) -> [TangerineGroup] {
        guard capability.known else { return groups }
        return groups.compactMap { group in
            let options = group.options.filter { capability.allows($0) }
            return options.isEmpty ? nil : TangerineGroup(title: group.title, options: options)
        }
    }
}
