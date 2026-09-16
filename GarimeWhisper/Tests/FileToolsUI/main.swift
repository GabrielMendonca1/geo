import AppKit
import PDFKit

var failures = 0
var checks = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("ok   · \(name)")
    } else {
        failures += 1
        print("FAIL · \(name) \(detail())")
    }
}

func pump(seconds: TimeInterval, until ready: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if ready() { return }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

let backendSource = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Sources/FileTools/Backend/FileToolsBackend.swift"

let appDelegateSource = CommandLine.arguments.count > 3
    ? CommandLine.arguments[3]
    : URL(fileURLWithPath: backendSource)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/AppDelegate.swift").path

let fixtureRoot: URL = {
    if CommandLine.arguments.count > 2 {
        return URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("garime-filetools-ui-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}()
try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

func fixture(_ name: String) -> URL {
    let url = fixtureRoot.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data([0x00, 0x01]))
    return url
}

let png = fixture("a.png")
let gif = fixture("b.gif")
let heif = fixture("c.heif")
let aiff = fixture("d.aiff")
let caf = fixture("e.caf")
let mp4 = fixture("f.mp4")
let wav = fixture("g.wav")
let pdf = fixture("h.pdf")
let tar = fixture("i.tar")

let bridge = FileToolsBridge()

func backendKind(_ url: URL) -> String {
    let kinds = bridge.capability(for: url).kinds
    if kinds.contains("extract") { return "archive" }
    if kinds.contains("mute") || kinds.contains("snapshot") { return "video" }
    if kinds.contains("normalize") || kinds.contains("channels") { return "audio" }
    if kinds.contains("crop") { return "image" }
    if kinds.contains("split") { return "pdf" }
    return "other"
}

check("GIF é imagem para o backend", backendKind(gif) == "image", backendKind(gif))
check("GIF é imagem na UI", TangerineCategory.of(gif) == .images)
check("HEIF é imagem na UI e no backend", TangerineCategory.of(heif) == .images && backendKind(heif) == "image")
check("AIFF é áudio na UI e no backend", TangerineCategory.of(aiff) == .audio && backendKind(aiff) == "audio")
check("CAF é áudio na UI e no backend", TangerineCategory.of(caf) == .audio && backendKind(caf) == "audio")

func offered(_ url: URL) -> [TangerineOption] {
    let capability = bridge.capability(for: url)
    let category = TangerineCategory.of(url) ?? .documents
    let convert = TangerineCatalog.convertGroups(
        category: category,
        sourceExtension: url.pathExtension,
        capability: capability
    )
    let tools = TangerineCatalog.toolGroups(category: category, capability: capability)
    return (convert + tools).flatMap(\.options)
}

for url in [png, gif, heif, aiff, caf, mp4, wav, pdf, tar] {
    let capability = bridge.capability(for: url)
    let options = offered(url)
    let impossible = options.filter { !capability.allows($0) }
    check("nada impossível oferecido para \(url.lastPathComponent)", impossible.isEmpty, impossible.map(\.id).description)
    check("origem não aparece como destino em \(url.lastPathComponent)",
          !options.contains { $0.format == TangerineCatalog.normalize(url.pathExtension) })
}

let gifFormats = Set(offered(gif).compactMap(\.format))
check("GIF oferece destinos de imagem", gifFormats.contains("png") && gifFormats.contains("webp"), gifFormats.description)
let gifBackendFormats = bridge.capability(for: gif).formats
check("GIF anima para vídeo porque o backend converte",
      gifBackendFormats.isSuperset(of: ["mp4", "mov", "mkv"])
        && gifFormats.isSuperset(of: ["mp4", "mov", "mkv"]),
      "ui=\(gifFormats.sorted()) backend=\(gifBackendFormats.sorted())")
let pngFormats = Set(offered(png).compactMap(\.format))
check("imagem parada não vira vídeo",
      pngFormats.isDisjoint(with: ["mp4", "mov", "mkv", "gif"]),
      pngFormats.sorted().description)
check("toda imagem vira ZIP como o backend anuncia",
      pngFormats.contains("zip") && gifFormats.contains("zip"),
      "png=\(pngFormats.sorted()) gif=\(gifFormats.sorted())")
let mp4Formats = Set(offered(mp4).compactMap(\.format))
check("vídeo oferece MOV e ZIP",
      mp4Formats.isSuperset(of: ["mov", "zip", "gif"]),
      mp4Formats.sorted().description)
check("GIF sem capacidade conhecida ainda mostra vídeo no fallback",
      Set(
        TangerineCatalog.convertGroups(category: .images, sourceExtension: "gif", capability: .unknown)
          .flatMap(\.options).compactMap(\.format)
      ).isSuperset(of: ["mp4", "mov", "mkv", "zip"]))
check("PNG sem capacidade conhecida não inventa vídeo",
      Set(
        TangerineCatalog.convertGroups(category: .images, sourceExtension: "png", capability: .unknown)
          .flatMap(\.options).compactMap(\.format)
      ).isDisjoint(with: ["mp4", "mov", "mkv"]))
check("formato novo do backend aparece mesmo fora da ordem fixa",
      Set(
        TangerineCatalog.convertGroups(
          category: .images,
          sourceExtension: "png",
          capability: TangerineCapability(kinds: ["convert"], formats: ["jpg", "avif"])
        ).flatMap(\.options).compactMap(\.format)
      ) == ["jpg", "avif"])
check("MOV e ZIP têm rótulo de verdade na roda",
      !(TangerineCatalog.formatDetail["mov"] ?? "").isEmpty
        && !(TangerineCatalog.formatDetail["zip"] ?? "").isEmpty)
check("ZIP é Pacote, não Mídia",
      TangerineCatalog.convertGroups(
        category: .images,
        sourceExtension: "png",
        capability: bridge.capability(for: png)
      ).first { $0.options.contains { $0.format == "zip" } }?.title == "Pacote")
check("MOV é Mídia na roda de vídeo",
      TangerineCatalog.convertGroups(
        category: .video,
        sourceExtension: "mp4",
        capability: bridge.capability(for: mp4)
      ).first { $0.options.contains { $0.format == "mov" } }?.title == "Mídia")

let aiffFormats = Set(offered(aiff).compactMap(\.format))
check("AIFF oferece destinos de áudio", aiffFormats.contains("wav") && aiffFormats.contains("mp3"), aiffFormats.description)

let kindOnly = TangerineCapability(kinds: ["convert"], formats: ["png"])
check("convert para formato fora da capacidade é recusado",
      !kindOnly.allows(TangerineOption(kind: "convert", format: "heic", title: "HEIC")))
check("convert para formato na capacidade é aceito",
      kindOnly.allows(TangerineOption(kind: "convert", format: "png", title: "PNG")))
check("capacidade desconhecida não esconde nada",
      TangerineCapability.unknown.allows(TangerineOption(kind: "qualquer", title: "X")))

let mixed = TangerineCapability.intersection([bridge.capability(for: png), bridge.capability(for: mp4)])
check("batch misto mantém só o que serve aos dois",
      mixed.kinds.isSubset(of: bridge.capability(for: png).kinds)
      && mixed.kinds.isSubset(of: bridge.capability(for: mp4).kinds))
check("batch PNG+MP4 não oferece WEBP", !mixed.formats.contains("webp"), mixed.formats.description)
check("batch PNG+MP4 ainda oferece empacotar", mixed.formats.contains("tar"))
check("batch PNG+MP4 não oferece mute", !mixed.kinds.contains("mute"))

let mixedGroups = TangerineCatalog.convertGroups(category: .images, sourceExtension: "", capability: mixed)
let mixedFormats = Set(mixedGroups.flatMap(\.options).compactMap(\.format))
check("roda de conversão do batch misto = interseção", mixedFormats.isSubset(of: mixed.formats), mixedFormats.description)
check("roda de conversão do batch misto não some com tar", mixedFormats.contains("tar"))

let barren = TangerineCapability(kinds: [], formats: [])
check("interseção vazia é estéril", barren.isBarren)
check("interseção vazia não oferece nada",
      TangerineCatalog.toolGroups(category: .images, capability: barren).isEmpty)

final class CountingEngine: TangerineRunning {
    var started = 0
    var capabilities: [String: TangerineCapability] = [:]
    func capability(for url: URL) -> TangerineCapability {
        capabilities[url.pathExtension] ?? .unknown
    }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        started += 1
        return TangerineOutcome(outputs: [input], message: nil)
    }
}

let counting = CountingEngine()
counting.capabilities["png"] = TangerineCapability(kinds: ["convert"], formats: ["webp", "tar"])
counting.capabilities["mp4"] = TangerineCapability(kinds: ["convert"], formats: ["mkv", "tar"])
let center = TangerineJobCenter(engine: counting)
let webp = TangerineOption(kind: "convert", format: "webp", title: "WEBP")
check("rejeição aponta exatamente o arquivo incompatível",
      center.rejects(option: webp, inputs: [png, mp4]).map(\.lastPathComponent) == [mp4.lastPathComponent])
check("opção comum não é rejeitada",
      center.rejects(option: TangerineOption(kind: "convert", format: "tar", title: "TAR"), inputs: [png, mp4]).isEmpty)
check("interseção do centro de trabalhos",
      center.capability(for: [png, mp4]).formats == ["tar"])
check("nenhum trabalho iniciado durante a checagem", counting.started == 0)

let snapshot = TangerineCatalog.toolGroups(category: .video)
    .flatMap(\.options)
    .first { $0.kind == "snapshot" }
let backendSnapshotExtension: String = {
    let source = (try? String(contentsOfFile: backendSource, encoding: .utf8)) ?? ""
    guard let range = source.range(of: "appendingPathComponent(\"snapshot.") else { return "?" }
    let rest = source[range.upperBound...]
    return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.startIndex)])
}()
check("rótulo do Quadro = formato realmente gerado (\(backendSnapshotExtension))",
      snapshot?.detail.lowercased() == (backendSnapshotExtension == "jpg" ? "jpeg" : backendSnapshotExtension),
      "rótulo=\(snapshot?.detail ?? "-") backend=\(backendSnapshotExtension)")

final class FailingEngine: TangerineRunning {
    func capability(for url: URL) -> TangerineCapability { .unknown }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "processFailed(\"ffmpeg exit 1\")"])
    }
}
let described = TangerineJobCenter.describe(
    NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "processFailed(\"ffmpeg exit 1\")"])
)
check("mensagem de falha carrega o motivo", described.contains("ffmpeg exit 1"), described)
check("mensagem de falha não corta no parêntese", !described.hasSuffix("processFailed("), described)

let toastCenter = TangerineJobCenter(engine: FailingEngine())
let created = toastCenter.submit(inputs: [png, mp4, wav], option: webp, values: [:])
check("um trabalho por arquivo", created.count == 3)
pump(seconds: 1.0) { created.allSatisfy { $0.state != .running } }
check("todos os trabalhos ficam listados", toastCenter.jobs.count == 3)
check("todas as falhas do lote aparecem", toastCenter.jobs.allSatisfy { $0.state == .failed })

final class CommittingEngine: TangerineRunning {
    let published: URL
    init(published: URL) { self.published = published }
    func capability(for url: URL) -> TangerineCapability { .unknown }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        try? await Task.sleep(nanoseconds: 60_000_000)
        return TangerineOutcome(outputs: [published], message: nil)
    }
}

let commitCenter = TangerineJobCenter(engine: CommittingEngine(published: png))
let commitJobs = commitCenter.submit(inputs: [mp4], option: webp, values: [:])
let commitJob = commitJobs[0]
commitCenter.cancel(commitJob)
check("cancelamento pedido é visível enquanto roda",
      commitJob.cancelRequested && commitJob.subtitle.hasPrefix("cancelando"),
      commitJob.subtitle)
pump(seconds: 2.0) { commitJob.state != .running }
check("commit vence cancelamento tardio", commitJob.state == .done, String(describing: commitJob.state))
check("saídas publicadas aparecem mesmo após cancelar", commitJob.outputs == [png], commitJob.outputs.description)

final class CancellingEngine: TangerineRunning {
    func capability(for url: URL) -> TangerineCapability { .unknown }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return TangerineOutcome(outputs: [input], message: nil)
    }
}

let abortCenter = TangerineJobCenter(engine: CancellingEngine())
let abortJob = abortCenter.submit(inputs: [mp4], option: webp, values: [:])[0]
abortCenter.cancel(abortJob)
pump(seconds: 2.0) { abortJob.state != .running }
check("cancelamento sem saída continua cancelado", abortJob.state == .cancelled, String(describing: abortJob.state))
check("cancelado não inventa saída", abortJob.outputs.isEmpty)

let wheel = RadialMenuView(frame: NSRect(x: 0, y: 0, width: RadialMenuView.side(scale: 0.72), height: RadialMenuView.side(scale: 0.72)))
wheel.scale = 0.72
wheel.groups = TangerineCatalog.toolGroups(category: .video)
wheel.selection = RadialMenuView.Selection(group: 0, option: 0)
let rendered = wheel.bitmapImageRepForCachingDisplay(in: wheel.bounds)
if let rendered {
    wheel.cacheDisplay(in: wheel.bounds, to: rendered)
}
check("roda renderiza sem estourar os limites", rendered != nil)

let cueWheel = RadialMenuView(frame: NSRect(x: 0, y: 0, width: RadialMenuView.side(scale: 1), height: RadialMenuView.side(scale: 1)))
cueWheel.groups = TangerineCatalog.convertGroups(category: .video, sourceExtension: "mp4", capability: bridge.capability(for: mp4))
cueWheel.selection = RadialMenuView.Selection(group: 0, option: 0)
var sectorCues = 0
var selectionCues = 0
let savedSector = RadialMenuView.playSectorChangedFeedback
let savedSelection = RadialMenuView.playSelectionFeedback
RadialMenuView.playSectorChangedFeedback = { sectorCues += 1 }
RadialMenuView.playSelectionFeedback = { selectionCues += 1 }
cueWheel.moveOption(1)
check("mudar de setor toca o cue ambiente uma vez", sectorCues == 1, String(sectorCues))
cueWheel.moveOption(0)
check("ficar no mesmo setor não toca nada", sectorCues == 1, String(sectorCues))
cueWheel.commit()
check("confirmar toca o cue de seleção", selectionCues == 1, String(selectionCues))
check("os cues do anel existem no catálogo de feedback",
      FeedbackCue(rawValue: "sectorChanged") != nil && FeedbackCue(rawValue: "selection") != nil)
check("tick de navegação é ambiente e confirmação não é alarme",
      FeedbackCue.sectorChanged.priority == .ambient && FeedbackCue.selection.priority == .lifecycle,
      "\(FeedbackCue.sectorChanged.priority) \(FeedbackCue.selection.priority)")
let appDelegateText = (try? String(contentsOfFile: appDelegateSource, encoding: .utf8)) ?? ""
func wiresHook(_ hook: String, _ cue: String) -> Bool {
    appDelegateText.split(separator: "\n").contains {
        $0.contains("\(hook) =") && $0.contains(".\(cue)")
    }
}
check("AppDelegate continua ligando os dois ganchos de som",
      wiresHook("RadialMenuView.playSectorChangedFeedback", "sectorChanged")
        && wiresHook("RadialMenuView.playSelectionFeedback", "selection"),
      appDelegateSource)
RadialMenuView.playSectorChangedFeedback = savedSector
RadialMenuView.playSelectionFeedback = savedSelection
check("ganchos voltam ao estado anterior",
      RadialMenuView.playSectorChangedFeedback == nil && RadialMenuView.playSelectionFeedback == nil)

func innerOverflow(scale: CGFloat, groups: [TangerineGroup]) -> [String] {
    let side = RadialMenuView.side(scale: scale)
    let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.scale = scale
    view.groups = groups
    return view.innerLabelOverflow()
}

let wheelCases: [(String, TangerineCategory)] = [
    ("vídeo", .video), ("imagens", .images), ("áudio", .audio),
    ("documentos", .documents), ("arquivos", .archives),
]
for scale in [0.72, 1.0] as [CGFloat] {
    for (name, category) in wheelCases {
        let tools = innerOverflow(scale: scale, groups: TangerineCatalog.toolGroups(category: category))
        let convert = innerOverflow(
            scale: scale,
            groups: TangerineCatalog.convertGroups(category: category, sourceExtension: "", capability: .unknown)
        )
        check("rótulo do anel interno cabe na faixa · \(name) · escala \(scale)",
              tools.isEmpty && convert.isEmpty, (tools + convert).description)
    }
    for url in [png, gif, mp4, wav, pdf, tar] {
        let real = innerOverflow(
            scale: scale,
            groups: TangerineCatalog.convertGroups(
                category: TangerineCategory.of(url) ?? .documents,
                sourceExtension: url.pathExtension,
                capability: bridge.capability(for: url)
            )
        )
        check("rótulo cabe na roda real do backend · \(url.lastPathComponent) · escala \(scale)",
              real.isEmpty, real.description)
    }
}

final class ShotlessEngine: TangerineRunning {
    private let realBridge = FileToolsBridge()
    func capability(for url: URL) -> TangerineCapability { realBridge.capability(for: url) }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        TangerineOutcome(outputs: [], message: nil)
    }
}

check("cartão do painel é branco de verdade", TangerineCard(frame: NSRect(x: 0, y: 0, width: 10, height: 10)).backgroundIsWhite)

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let dashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: ShotlessEngine()))
let photo = fixture("foto.heic")
let pngOption = TangerineOption(kind: "convert", format: "png", title: "PNG", detail: "sem perdas")
dashboard.load(inputs: [photo], option: pngOption, mode: .convert)

let convertWheel = dashboard.wheel(for: .convert)
let toolsWheel = dashboard.wheel(for: .tools)
check("as duas rodas ficam montadas ao mesmo tempo",
      !convertWheel.groups.isEmpty && !toolsWheel.groups.isEmpty,
      "convert=\(convertWheel.groups.count) tools=\(toolsWheel.groups.count)")
check("roda da esquerda é a de conversão (Shift)", convertWheel.mode == .convert)
check("roda da direita é a de ferramentas (Shift+Option)", toolsWheel.mode == .tools)
check("escolha do usuário marca só a roda ativa",
      convertWheel.currentOption?.format == "png" && toolsWheel.currentOption == nil,
      "\(String(describing: convertWheel.currentOption?.id)) / \(String(describing: toolsWheel.currentOption?.id))")
check("roda inativa fica apagada, sem laranja", !convertWheel.dimmed && toolsWheel.dimmed)
check("cartão ativo é o da roda escolhida",
      dashboard.card(for: .convert).active && !dashboard.card(for: .tools).active)
check("os dois cartões das rodas são brancos",
      dashboard.card(for: .convert).backgroundIsWhite && dashboard.card(for: .tools).backgroundIsWhite)

for (w, h) in [(TangerineDashboard.minimumWidth, TangerineDashboard.minimumHeight), (1180, 840), (1600, 1020)] as [(CGFloat, CGFloat)] {
    dashboard.resizeForTests(width: w, height: h)
    let left = dashboard.card(for: .convert)
    let right = dashboard.card(for: .tools)
    check("rodas lado a lado sem sobreposição · \(Int(w))x\(Int(h))",
          left.frame.maxX <= right.frame.minX && abs(left.frame.width - right.frame.width) < 0.5,
          "\(left.frame) \(right.frame)")
    check("cartões das rodas cabem na janela · \(Int(w))x\(Int(h))",
          right.frame.maxX <= w - 20 && right.frame.maxY <= h,
          right.frame.debugDescription)
    for mode in [TangerineMode.convert, .tools] {
        let card = dashboard.card(for: mode)
        let wheelView = dashboard.wheel(for: mode)
        check("roda \(mode.title) dentro do cartão · \(Int(w))x\(Int(h))",
              card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(wheelView.frame),
              "\(wheelView.frame) em \(card.bounds)")
        check("escala responsiva mantém rótulos inteiros · \(mode.title) · \(Int(w))x\(Int(h))",
              wheelView.innerLabelOverflow().isEmpty,
              wheelView.innerLabelOverflow().description)
    }
}

dashboard.resizeForTests(width: 1180, height: 840)
for category in TangerineCategory.allCases {
    for mode in [TangerineMode.convert, .tools] {
        let scale = dashboard.wheelScale(for: dashboard.card(for: mode))
        let side = RadialMenuView.side(scale: scale)
        let probe = RadialMenuView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        probe.scale = scale
        probe.groups = mode == .convert
            ? TangerineCatalog.convertGroups(category: category, sourceExtension: "", capability: .unknown)
            : TangerineCatalog.toolGroups(category: category, capability: .unknown)
        check("rótulo cabe na escala do painel · \(category.title) · \(mode.title)",
              probe.innerLabelOverflow().isEmpty,
              probe.innerLabelOverflow().description)
    }
}

// MARK: - combinação multi-entrada (merge / collage) contra o backend real

func realImage(_ name: String, width: Int, height: Int, red: CGFloat) -> URL {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: red, green: 0.4, blue: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let url = fixtureRoot.appendingPathComponent(name)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    return url
}

func realPDF(_ name: String, width: CGFloat) -> URL {
    let document = PDFDocument()
    let image = NSImage(size: NSSize(width: width, height: 120))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: 120).fill()
    image.unlockFocus()
    if let page = PDFPage(image: image) { document.insert(page, at: 0) }
    let url = fixtureRoot.appendingPathComponent(name)
    _ = document.write(to: url)
    return url
}

func await_<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) -> Result<T, Error> {
    var outcome: Result<T, Error>?
    Task {
        do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
    }
    pump(seconds: seconds) { outcome != nil }
    return outcome ?? .failure(NSError(domain: "timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "esgotou o tempo do teste"]))
}

let realBridge = FileToolsBridge()
let backend = FileToolsBackend()

let photoA = realImage("colagem-a.png", width: 320, height: 200, red: 0.9)
let photoB = realImage("colagem-b.png", width: 200, height: 320, red: 0.2)
let docA = realPDF("juntar-a.pdf", width: 200)
let docB = realPDF("juntar-b.pdf", width: 400)

check("backend anuncia collage e merge para imagem",
      Set(backend.capabilities(for: photoA).operations.map(\.rawValue)).isSuperset(of: ["collage", "merge"]))
check("backend anuncia merge sem collage para PDF",
      backend.capabilities(for: docA).operations.map(\.rawValue).contains("merge")
      && !backend.capabilities(for: docA).operations.map(\.rawValue).contains("collage"))

check("duas imagens habilitam juntar e colagem",
      realBridge.batchKinds(for: [photoA, photoB]) == ["merge", "collage"],
      String(describing: realBridge.batchKinds(for: [photoA, photoB])))
check("dois PDFs habilitam só juntar",
      realBridge.batchKinds(for: [docA, docB]) == ["merge"],
      String(describing: realBridge.batchKinds(for: [docA, docB])))
check("famílias misturadas não habilitam combinação",
      realBridge.batchKinds(for: [photoA, mp4]) == [])
check("um arquivo só não habilita combinação", realBridge.batchKinds(for: [photoA]) == [])

let imageBatchCapability = TangerineJobCenter(engine: realBridge).capability(for: [photoA, photoB])
let imageBatchGroups = TangerineCatalog.batchGroups(category: .images, inputCount: 2, capability: imageBatchCapability)
let imageBatchIDs = imageBatchGroups.flatMap(\.options).map(\.id)
check("grupo Combinar aparece com 2 imagens", imageBatchGroups.count == 1 && imageBatchGroups[0].title == "Combinar")
check("Combinar oferece juntar em PDF e colagem",
      imageBatchIDs.contains("merge:pdf") && imageBatchIDs.contains("collage:png"),
      imageBatchIDs.description)
check("Combinar some com um arquivo só",
      TangerineCatalog.batchGroups(category: .images, inputCount: 1, capability: imageBatchCapability).isEmpty)
check("Combinar some quando o backend não anuncia nada",
      TangerineCatalog.batchGroups(
        category: .images, inputCount: 3,
        capability: TangerineCapability(kinds: ["convert"], formats: ["png"], batchKinds: [])
      ).isEmpty)
let pdfBatchIDs = TangerineCatalog.batchGroups(
    category: .documents, inputCount: 2,
    capability: TangerineJobCenter(engine: realBridge).capability(for: [docA, docB])
).flatMap(\.options).map(\.id)
check("PDF oferece juntar mas não colagem", pdfBatchIDs == ["merge:pdf"], pdfBatchIDs.description)

check("imagem + PDF continua podendo juntar",
      realBridge.batchKinds(for: [photoA, docA]) == ["merge"],
      String(describing: realBridge.batchKinds(for: [photoA, docA])))
let mixedDocDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
mixedDocDashboard.load(inputs: [photoA, docA], option: TangerineCatalog.mergeOption(format: "pdf"), mode: .tools)
check("painel acha Juntar PDF para imagem + PDF",
      mixedDocDashboard.wheel(for: .tools).currentOption?.id == "merge:pdf",
      String(describing: mixedDocDashboard.wheel(for: .tools).currentOption?.id))

check("todo formato de Combinar existe no backend",
      (TangerineCatalog.mergeTargets.values.flatMap { $0 } + TangerineCatalog.collageTargets)
        .allSatisfy { FileToolsFormat(rawValue: $0) != nil })

// mapeamento UI -> operação real do backend
let collageOption = TangerineCatalog.collageOption(format: "png")
var collageValues: [String: TangerineValue] = [:]
for param in collageOption.params {
    let raw: String
    switch param.id {
    case "layout": raw = "grade"
    case "columns": raw = "2"
    case "spacing": raw = "4"
    case "margin": raw = "10"
    case "width": raw = "1000"
    case "fit": raw = "cobrir"
    default: raw = "#101010"
    }
    if case let .value(value) = param.parse(raw) { collageValues[param.id] = value }
}
let mappedCollage = try? FileToolsBridge.operation(option: collageOption, values: collageValues)
if case let .collage(options, format)? = mappedCollage {
    check("colagem leva layout, colunas, espaço, margem, largura, ajuste e fundo ao backend",
          options == FileToolsCollageOptions(
            layout: .grid, canvasWidth: 1_000, columns: 2, spacing: 4,
            margin: 10, backgroundHex: "#101010", fit: .cover
          ) && format == .png,
          String(describing: options))
} else {
    check("colagem vira FileToolsOperation.collage", false, String(describing: mappedCollage))
}
for (label, expected) in [("linha", FileToolsCollageLayout.row), ("coluna", .column), ("destaque", .featured)] {
    var values = collageValues
    if case let .value(value) = collageOption.params[0].parse(label) { values["layout"] = value }
    if case let .collage(options, _)? = try? FileToolsBridge.operation(option: collageOption, values: values) {
        check("arranjo \(label) chega como \(expected) no backend", options.layout == expected, String(describing: options.layout))
    } else {
        check("arranjo \(label) mapeia", false)
    }
}
if case let .merge(format)? = try? FileToolsBridge.operation(option: TangerineCatalog.mergeOption(format: "pdf"), values: [:]) {
    check("juntar vira FileToolsOperation.merge(to:)", format == .pdf)
} else {
    check("juntar vira FileToolsOperation.merge(to:)", false)
}

// parâmetros textuais
let colorParam = TangerineCatalog.collageParams.first { $0.id == "background" }!
check("cor curta vira hex completo", colorParam.parse("#FFF") == .value(.text("#ffffff")))
check("cor sem # é aceita", colorParam.parse("101010") == .value(.text("#101010")))
check("cor inválida é recusada", colorParam.parse("laranja") == .problem("Fundo: use #rrggbb ou transparent"))
check("fundo transparente é aceito como o backend aceita", colorParam.parse("transparente") == .value(.text("transparent")))
let layoutParam = TangerineCatalog.collageParams[0]
check("arranjo aceita rótulo em português", layoutParam.parse("coluna") == .value(.text("column")))
check("arranjo aceita valor do backend", layoutParam.parse("featured") == .value(.text("featured")))
if case let .problem(reason) = layoutParam.parse("diagonal") {
    check("arranjo inválido lista as opções", reason.contains("grid") && reason.contains("featured"), reason)
} else {
    check("arranjo inválido é recusado", false)
}

// regras que dependem do conjunto
let threeImages: [String: TangerineValue] = ["layout": .text("grid"), "columns": .number(5), "width": .number(1_000), "margin": .number(10)]
check("colunas acima do número de imagens são barradas na UI",
      TangerineCatalog.batchProblem(option: collageOption, values: threeImages, inputCount: 3) != nil)
check("colunas dentro do conjunto passam",
      TangerineCatalog.batchProblem(
        option: collageOption,
        values: ["layout": .text("grid"), "columns": .number(2), "width": .number(1_000), "margin": .number(10)],
        inputCount: 3
      ) == nil)
check("margem maior que a largura é barrada",
      TangerineCatalog.batchProblem(
        option: collageOption,
        values: ["layout": .text("row"), "width": .number(1_000), "margin": .number(600)],
        inputCount: 3
      ) != nil)

// um job para o conjunto, nunca um por arquivo
final class BatchSpyEngine: TangerineRunning {
    var perFileCalls = 0
    var batchCalls: [[URL]] = []
    func capability(for url: URL) -> TangerineCapability { .unknown }
    func batchKinds(for urls: [URL]) -> Set<String>? { ["merge", "collage"] }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        perFileCalls += 1
        return TangerineOutcome(outputs: [input], message: nil)
    }
    func runBatch(inputs: [URL], option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        batchCalls.append(inputs)
        return TangerineOutcome(outputs: [inputs[0]], message: nil)
    }
}

let spy = BatchSpyEngine()
let batchCenter = TangerineJobCenter(engine: spy)
let mergeOption = TangerineCatalog.mergeOption(format: "pdf")
let batchJobs = batchCenter.submit(inputs: [docA, docB, photoA], option: mergeOption, values: [:])
check("combinar cria um único trabalho", batchJobs.count == 1, batchJobs.count.description)
check("trabalho de combinação guarda todas as entradas", batchJobs[0].inputs.count == 3)
check("rótulo do trabalho mostra o conjunto", batchJobs[0].title == "Juntar PDF · 3 arquivos", batchJobs[0].title)
pump(seconds: 1.0) { batchJobs[0].state != .running }
check("combinação não roda uma vez por arquivo", spy.perFileCalls == 0 && spy.batchCalls.count == 1,
      "perFile=\(spy.perFileCalls) batch=\(spy.batchCalls.count)")
check("ordem escolhida chega intacta ao motor",
      spy.batchCalls.first?.map(\.lastPathComponent) == [docA, docB, photoA].map(\.lastPathComponent),
      String(describing: spy.batchCalls.first?.map(\.lastPathComponent)))

let perFileJobs = batchCenter.submit(inputs: [docA, docB], option: TangerineOption(kind: "convert", format: "png", title: "PNG"), values: [:])
check("operação por arquivo continua um job por arquivo", perFileJobs.count == 2)
pump(seconds: 1.0) { perFileJobs.allSatisfy { $0.state != .running } }
check("operação por arquivo usa o caminho por arquivo", spy.perFileCalls == 2, spy.perFileCalls.description)

check("combinar com um arquivo só é barrado antes de enviar",
      batchCenter.blocker(option: mergeOption, inputs: [docA])?.contains("pelo menos 2") == true,
      String(describing: batchCenter.blocker(option: mergeOption, inputs: [docA])))
check("combinar com conjunto válido não é barrado",
      batchCenter.blocker(option: mergeOption, inputs: [docA, docB]) == nil)

final class NoBatchEngine: TangerineRunning {
    func capability(for url: URL) -> TangerineCapability { .unknown }
    func batchKinds(for urls: [URL]) -> Set<String>? { [] }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        TangerineOutcome(outputs: [input], message: nil)
    }
}
let refusing = TangerineJobCenter(engine: NoBatchEngine())
check("motor sem combinação barra a opção",
      refusing.blocker(option: mergeOption, inputs: [docA, docB]) != nil)
let refusedJob = refusing.submit(inputs: [docA, docB], option: mergeOption, values: [:])[0]
pump(seconds: 1.0) { refusedJob.state != .running }
check("motor sem runBatch falha em vez de fingir sucesso",
      refusedJob.state == .failed && refusedJob.outputs.isEmpty,
      "\(refusedJob.state) \(refusedJob.subtitle)")

// execução real ponta a ponta pelo backend
let mergeOut = fixtureRoot.appendingPathComponent("saida-merge", isDirectory: true)
try? FileManager.default.createDirectory(at: mergeOut, withIntermediateDirectories: true)
let mergedForward = await_(20) {
    try await realBridge.runBatch(inputs: [docA, docB], option: mergeOption, values: [:], outputDirectory: mergeOut)
}
switch mergedForward {
case let .success(outcome):
    check("juntar real produz uma saída só", outcome.outputs.count == 1, outcome.outputs.description)
    let merged = outcome.outputs.first.flatMap { PDFDocument(url: $0) }
    check("juntar real soma as páginas", merged?.pageCount == 2, String(describing: merged?.pageCount))
    check("primeira página é a primeira da lista",
          (merged?.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) < (merged?.page(at: 1)?.bounds(for: .mediaBox).width ?? 0),
          String(describing: merged?.page(at: 0)?.bounds(for: .mediaBox)))
case let .failure(error):
    check("juntar real roda pelo backend", false, TangerineJobCenter.describe(error))
}

let mergedReversed = await_(20) {
    try await realBridge.runBatch(inputs: [docB, docA], option: mergeOption, values: [:], outputDirectory: mergeOut)
}
if case let .success(outcome) = mergedReversed, let merged = outcome.outputs.first.flatMap({ PDFDocument(url: $0) }) {
    check("inverter a ordem inverte o resultado real",
          merged.page(at: 0)?.bounds(for: .mediaBox).width ?? 0 > merged.page(at: 1)?.bounds(for: .mediaBox).width ?? 0,
          String(describing: merged.page(at: 0)?.bounds(for: .mediaBox)))
} else {
    check("inverter a ordem roda pelo backend", false, String(describing: mergedReversed))
}

let collageOut = fixtureRoot.appendingPathComponent("saida-collage", isDirectory: true)
try? FileManager.default.createDirectory(at: collageOut, withIntermediateDirectories: true)
var realCollageValues: [String: TangerineValue] = [:]
for param in collageOption.params {
    let raw: String
    switch param.id {
    case "layout": raw = "grade"
    case "columns": raw = "2"
    case "spacing": raw = "10"
    case "margin": raw = "20"
    case "width": raw = "800"
    case "fit": raw = "conter"
    default: raw = "#204060"
    }
    if case let .value(value) = param.parse(raw) { realCollageValues[param.id] = value }
}
let collaged = await_(20) {
    try await realBridge.runBatch(inputs: [photoA, photoB], option: collageOption, values: realCollageValues, outputDirectory: collageOut)
}
switch collaged {
case let .success(outcome):
    check("colagem real produz uma imagem só", outcome.outputs.count == 1, outcome.outputs.description)
    let image = outcome.outputs.first.flatMap { NSImage(contentsOf: $0) }
    let rep = image?.representations.first
    check("colagem real respeita a largura pedida", rep?.pixelsWide == 800, String(describing: rep?.pixelsWide))
    check("colagem real cabe numa linha de duas colunas",
          (rep?.pixelsHigh ?? 0) > 0 && (rep?.pixelsHigh ?? .max) < 800,
          String(describing: rep?.pixelsHigh))
case let .failure(error):
    check("colagem real roda pelo backend", false, TangerineJobCenter.describe(error))
}

// fundo transparente de verdade: alfa zero no canto da margem
var transparentValues = realCollageValues
transparentValues["background"] = .text("transparent")
let transparentCollage = await_(20) {
    try await realBridge.runBatch(inputs: [photoA, photoB], option: collageOption, values: transparentValues, outputDirectory: collageOut)
}
if case let .success(outcome) = transparentCollage,
   let output = outcome.outputs.first,
   let rep = NSImage(contentsOf: output)?.representations.first as? NSBitmapImageRep {
    check("fundo transparente sai transparente de verdade",
          (rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.01,
          String(describing: rep.colorAt(x: 1, y: 1)?.alphaComponent))
} else {
    check("colagem transparente roda pelo backend", false, String(describing: transparentCollage))
}

let badCollage = await_(20) {
    try await realBridge.runBatch(
        inputs: [photoA, photoB],
        option: collageOption,
        values: ["layout": .text("grid"), "columns": .number(9), "width": .number(800), "margin": .number(20), "spacing": .number(10), "background": .text("#204060")],
        outputDirectory: collageOut
    )
}
if case .failure = badCollage {
    check("backend recusa colunas impossíveis e a UI não inventa saída", true)
} else {
    check("backend recusa colunas impossíveis", false, "aceitou colunas > imagens")
}

// parâmetros ricos e ordem no painel
let orderDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
orderDashboard.load(inputs: [photoA, photoB, png], option: TangerineOption(kind: "convert", format: "jpg", title: "JPG"), mode: .convert)
check("painel guarda a ordem recebida",
      orderDashboard.orderedInputs.map(\.lastPathComponent) == [photoA, photoB, png].map(\.lastPathComponent))
check("mover para cima troca vizinhos", orderDashboard.moveInput(from: 1, by: -1))
check("ordem depois de mover",
      orderDashboard.orderedInputs.map(\.lastPathComponent) == [photoB, photoA, png].map(\.lastPathComponent),
      orderDashboard.orderedInputs.map(\.lastPathComponent).description)
check("não move além da borda", !orderDashboard.moveInput(from: 0, by: -1) && !orderDashboard.moveInput(from: 2, by: 1))
check("remover tira exatamente um", orderDashboard.removeInput(at: 2) && orderDashboard.orderedInputs.count == 2)
check("remover fora da lista não faz nada", !orderDashboard.removeInput(at: 7))

let batchDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: spy))
batchDashboard.load(inputs: [photoA, photoB], option: TangerineCatalog.collageOption(format: "png"), mode: .tools)
check("painel encontra a colagem na roda de ferramentas",
      batchDashboard.wheel(for: .tools).currentOption?.id == "collage:png",
      String(describing: batchDashboard.wheel(for: .tools).currentOption?.id))
check("colagem mostra os sete ajustes reais",
      batchDashboard.wheel(for: .tools).currentOption?.params.map(\.id) == ["layout", "columns", "spacing", "margin", "width", "fit", "background"],
      String(describing: batchDashboard.wheel(for: .tools).currentOption?.params.map(\.id)))
let before = spy.batchCalls.count
check("aplicar colagem envia um único trabalho", batchDashboard.runSelection())
pump(seconds: 1.0) { spy.batchCalls.count > before }
check("painel enviou pelo caminho multi-entrada", spy.batchCalls.count == before + 1, spy.batchCalls.count.description)
check("painel enviou as duas imagens juntas",
      spy.batchCalls.last?.count == 2,
      String(describing: spy.batchCalls.last?.count))
check("cor inválida vira quadradinho vazio, não cor falsa", TangerineDashboard.color(from: "laranja") == nil)
check("cor válida vira quadradinho de verdade", TangerineDashboard.color(from: "#ff0000") != nil)

// parâmetros de conflito: a roda de combinação some quando o arquivo é um só
let soloDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
soloDashboard.load(inputs: [photoA], option: TangerineOption(kind: "compress", title: "Comprimir"), mode: .tools)
check("um arquivo só não mostra Combinar",
      !soloDashboard.wheel(for: .tools).groups.contains { $0.title == "Combinar" },
      soloDashboard.wheel(for: .tools).groups.map(\.title).description)

// várias entradas do mesmo tipo não oferecem o próprio tipo
let sameTypeDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
sameTypeDashboard.load(inputs: [photoA, photoB], option: TangerineOption(kind: "compress", title: "Comprimir"), mode: .tools)
let sameTypeFormats = Set(sameTypeDashboard.wheel(for: .convert).groups.flatMap(\.options).compactMap(\.format))
check("duas PNGs não oferecem converter para PNG", !sameTypeFormats.contains("png"), sameTypeFormats.sorted().description)
check("duas PNGs ainda oferecem os outros destinos", sameTypeFormats.contains("jpg") && sameTypeFormats.contains("tiff"))
let mixedDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
mixedDashboard.load(inputs: [photoA, gif], option: TangerineOption(kind: "compress", title: "Comprimir"), mode: .tools)
let mixedTypeFormats = Set(mixedDashboard.wheel(for: .convert).groups.flatMap(\.options).compactMap(\.format))
check("tipos diferentes na mesma família mantêm os dois destinos",
      mixedTypeFormats.contains("png") && mixedTypeFormats.contains("jpg"),
      mixedTypeFormats.sorted().description)

// contador honesto de cobertura
let coverDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: realBridge))
check("sem arquivos o contador não promete nada",
      coverDashboard.coverageSummary == "escolha arquivos para ver o que dá",
      coverDashboard.coverageSummary)
coverDashboard.load(inputs: [photoA, photoB], option: TangerineOption(kind: "compress", title: "Comprimir"), mode: .tools)
let coverText = coverDashboard.coverageSummary
let coverConversions = coverDashboard.wheel(for: .convert).groups.flatMap(\.options).count
let coverCombos = coverDashboard.wheel(for: .tools).groups.flatMap(\.options).filter(\.isBatch).count
check("contador reflete as rodas montadas",
      coverText.hasPrefix("\(coverConversions) conversões") && coverText.contains("\(coverCombos) combinações"),
      coverText)
check("contador não inventa as 82 do site", !coverText.contains("82"), coverText)
check("contador conta conversões reais do backend",
      coverConversions == Set(backend.capabilities(for: photoA).conversionTargets.map(\.rawValue))
        .subtracting(["png"]).count,
      "\(coverConversions)")

// paridade catalogo x backend, incluindo TXT
let txt = fixture("nota.txt")
check("TXT é documento na UI", TangerineCategory.of(txt) == .documents)
for url in [png, gif, heif, aiff, caf, mp4, wav, pdf, tar, txt] {
    let announced = Set(backend.capabilities(for: url).conversionTargets.map(\.rawValue))
        .subtracting([TangerineCatalog.normalize(url.pathExtension)])
    let offeredFormats = Set(
        TangerineCatalog.convertGroups(
            category: TangerineCategory.of(url) ?? .documents,
            sourceExtension: url.pathExtension,
            capability: realBridge.capability(for: url)
        ).flatMap(\.options).compactMap(\.format)
    )
    check("UI oferece exatamente o que o backend converte · \(url.lastPathComponent)",
          offeredFormats == announced,
          "ui=\(offeredFormats.sorted()) backend=\(announced.sorted())")
}

let secondsParam = TangerineParam(id: "start", label: "Início", kind: .seconds, fallback: "0", hint: "s")
let decimalParam = TangerineParam(id: "rate", label: "Velocidade", kind: .decimal(min: 0.25, max: 4), fallback: "1", hint: "x")
let integerParam = TangerineParam(id: "quality", label: "Qualidade", kind: .integer(min: 1, max: 100), fallback: "80", hint: "1-100")
check("segundos infinitos são recusados", secondsParam.parse("1e400") == .problem("Início: número inválido"),
      String(describing: secondsParam.parse("1e400")))
check("segundos infinitos negativos são recusados", secondsParam.parse("-1e400") == .problem("Início: número inválido"),
      String(describing: secondsParam.parse("-1e400")))
check("tempo mm:ss infinito é recusado", secondsParam.parse("0:1e400") == .problem("Início: tempo inválido"),
      String(describing: secondsParam.parse("0:1e400")))
check("segundos finitos continuam passando", secondsParam.parse("1.5") == .value(1.5))
check("tempo mm:ss finito continua passando", secondsParam.parse("1:30") == .value(90))
check("decimal infinito é recusado", decimalParam.parse("1e400") == .problem("Velocidade: número inválido"),
      String(describing: decimalParam.parse("1e400")))
check("inteiro infinito é recusado", integerParam.parse("1e400") == .problem("Qualidade: número inválido"),
      String(describing: integerParam.parse("1e400")))
check("nan é recusado", secondsParam.parse("nan") == .problem("Início: número inválido"),
      String(describing: secondsParam.parse("nan")))

final class KeySpyEngine: TangerineRunning {
    private let realBridge = FileToolsBridge()
    var runs = 0
    func capability(for url: URL) -> TangerineCapability { realBridge.capability(for: url) }
    func run(input: URL, option: TangerineOption, values: [String: TangerineValue], outputDirectory: URL?) async throws -> TangerineOutcome {
        runs += 1
        return TangerineOutcome(outputs: [input], message: nil)
    }
}

let keyEngine = KeySpyEngine()
let keyDashboard = TangerineDashboard(jobs: TangerineJobCenter(engine: keyEngine))
keyDashboard.load(inputs: [photoA], option: TangerineOption(kind: "convert", format: "jpg", title: "JPG"), mode: .convert)
var keySelectionCues = 0
RadialMenuView.playSelectionFeedback = { keySelectionCues += 1 }
let returnEvent = NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "\r",
    charactersIgnoringModifiers: "\r",
    isARepeat: false,
    keyCode: 36
)
check("evento de Enter foi criado", returnEvent != nil)
if let returnEvent {
    keyDashboard.rootView.keyDown(with: returnEvent)
}
check("Enter toca o cue de confirmação uma vez", keySelectionCues == 1, String(keySelectionCues))
pump(seconds: 2.0) { keyEngine.runs > 0 }
check("Enter envia exatamente um trabalho", keyEngine.runs == 1, String(keyEngine.runs))
RadialMenuView.playSelectionFeedback = nil

var completedCues = 0
var errorCues = 0
var cancelledCues = 0
TangerineJobCenter.playCompletedFeedback = { completedCues += 1 }
TangerineJobCenter.playErrorFeedback = { errorCues += 1 }
TangerineJobCenter.playCancelledFeedback = { cancelledCues += 1 }

pump(seconds: 0.6)
completedCues = 0
errorCues = 0
cancelledCues = 0

let doneCenter = TangerineJobCenter(engine: CountingEngine())
let doneJob = doneCenter.submit(inputs: [png], option: webp, values: [:])[0]
pump(seconds: 2.0) { doneJob.state != .running }
check("trabalho concluído toca o cue de conclusão", completedCues == 1 && doneJob.state == .done,
      "\(completedCues) \(String(describing: doneJob.state))")
check("conclusão não toca erro nem cancelamento", errorCues == 0 && cancelledCues == 0,
      "\(errorCues) \(cancelledCues)")

let failCenter = TangerineJobCenter(engine: FailingEngine())
let failJob = failCenter.submit(inputs: [png], option: webp, values: [:])[0]
pump(seconds: 2.0) { failJob.state != .running }
check("falha toca o cue de erro", errorCues == 1 && failJob.state == .failed,
      "\(errorCues) \(String(describing: failJob.state))")

let cancelCenter = TangerineJobCenter(engine: CancellingEngine())
let cancelJob = cancelCenter.submit(inputs: [png], option: webp, values: [:])[0]
cancelCenter.cancel(cancelJob)
pump(seconds: 2.0) { cancelJob.state != .running }
check("cancelamento toca o cue de cancelado", cancelledCues == 1 && cancelJob.state == .cancelled,
      "\(cancelledCues) \(String(describing: cancelJob.state))")
check("cancelamento não toca conclusão extra", completedCues == 1, String(completedCues))

check("AppDelegate liga os ganchos de som dos trabalhos",
      wiresHook("TangerineJobCenter.playCompletedFeedback", "completed")
        && wiresHook("TangerineJobCenter.playCancelledFeedback", "cancelled")
        && wiresHook("TangerineJobCenter.playErrorFeedback", "error"),
      appDelegateSource)
check("os cues de trabalho existem no catálogo de feedback",
      FeedbackCue(rawValue: "completed") != nil
        && FeedbackCue(rawValue: "cancelled") != nil
        && FeedbackCue(rawValue: "error") != nil)

TangerineJobCenter.playCompletedFeedback = nil
TangerineJobCenter.playErrorFeedback = nil
TangerineJobCenter.playCancelledFeedback = nil
check("ganchos dos trabalhos voltam ao estado anterior",
      TangerineJobCenter.playCompletedFeedback == nil
        && TangerineJobCenter.playErrorFeedback == nil
        && TangerineJobCenter.playCancelledFeedback == nil)

print("\n\(checks - failures)/\(checks) checks passaram")
exit(failures == 0 ? 0 : 1)
