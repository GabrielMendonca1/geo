import AppKit
import ImageIO

var checks = 0
var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() { print("ok   · \(name)") }
    else { failures += 1; print("FAIL · \(name) \(detail())") }
}

func pump(_ seconds: TimeInterval, until ready: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !ready() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

final class RecordingEngine: TangerineRunning {
    private let lock = NSLock()
    private var recordedRuns: [(URL, TangerineOption, [String: TangerineValue])] = []
    var capabilities: [String: TangerineCapability] = [:]

    var runs: [(URL, TangerineOption, [String: TangerineValue])] {
        lock.withLock { recordedRuns }
    }

    func capability(for url: URL) -> TangerineCapability {
        capabilities[url.pathExtension] ?? .unknown
    }

    func run(
        input: URL,
        option: TangerineOption,
        values: [String: TangerineValue],
        outputDirectory: URL?
    ) async throws -> TangerineOutcome {
        lock.withLock { recordedRuns.append((input, option, values)) }
        return TangerineOutcome(outputs: [input], message: nil)
    }
}

func makeMetadataPNGFixture(at url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 32,
        pixelsHigh: 20,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let image = rep.cgImage,
       let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw NSError(domain: "RadialActionsFixture", code: 1) }

    let pngMetadata: [CFString: Any] = [
        kCGImagePropertyPNGAuthor: "Garime RadialActions",
        kCGImagePropertyPNGDescription: "metadata that the direct action must remove"
    ]
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyPNGDictionary: pngMetadata
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "RadialActionsFixture", code: 2)
    }
}

func imageProperties(_ url: URL) -> NSDictionary? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
}

func pngAuthor(_ url: URL) -> String? {
    let png = imageProperties(url)?[kCGImagePropertyPNGDictionary] as? NSDictionary
    return png?[kCGImagePropertyPNGAuthor] as? String
}

_ = NSApplication.shared
let fm = FileManager.default
let fixtureRoot = fm.temporaryDirectory.appendingPathComponent("garime-radial-actions-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixtureRoot) }

let first = fixtureRoot.appendingPathComponent("first.png")
let second = fixtureRoot.appendingPathComponent("second.png")
let remote = URL(string: "https://example.test/image.png")!
let direct = TangerineOption(kind: "removeMetadata", title: "Metadados")
let crop = TangerineOption(
    kind: "crop",
    title: "Recortar",
    params: [TangerineParam(id: "width", label: "Largura", kind: .integer(min: 1, max: 100), fallback: "10", hint: "px")]
)

print("== unidade da política de ação compacta ==")
let engine = RecordingEngine()
engine.capabilities["png"] = TangerineCapability(
    kinds: ["convert", "removeMetadata", "crop"],
    formats: ["jpg", "webp"]
)
let center = TangerineJobCenter(engine: engine)
var parameterPresentations = 0
var submitted: [TangerineJob] = []
let action = TangerineCompactAction(jobs: center) { _, _ in parameterPresentations += 1 }
action.onSubmitted = { submitted = $0 }

var selectionSounds = 0
let oldSound = RadialMenuView.playSelectionFeedback
RadialMenuView.playSelectionFeedback = { selectionSounds += 1 }
defer { RadialMenuView.playSelectionFeedback = oldSound }

let result = action.perform(inputs: [second, first], option: direct)
check("ação simples é enviada diretamente", result == .submitted(2))
check("ação direta não abre editor de parâmetros", parameterPresentations == 0)
check("um job por arquivo é criado", submitted.count == 2)
check("ordem original dos arquivos é preservada", submitted.map(\.input) == [second, first])
check("seleção aceita usa o callback de som existente", selectionSounds == 1)
pump(0.5) { engine.runs.count == 2 }
check("engine recebe todos os arquivos", Set(engine.runs.map(\.0)) == Set([second, first]))

let parameterResult = action.perform(inputs: [first], option: crop)
check("ferramenta parametrizada pede apenas UI compacta", parameterResult == .awaitingParameters)
check("UI de parâmetros não ativa sincronicamente durante o drop", parameterPresentations == 0)
pump(0.2) { parameterPresentations == 1 }
check("UI compacta é apresentada uma vez depois do retorno", parameterPresentations == 1)
check("ferramenta parametrizada não roda com defaults silenciosamente", submitted.count == 2)

let rejected = action.perform(inputs: [remote], option: direct)
check("URL não-file de outro app é recusada", rejected == .rejected)
check("URL recusada não abre editor", parameterPresentations == 1)
check("URL recusada não produz job", center.jobs.count == 2)

let groups = action.groups(for: [second, first], mode: .convert)
let formats = groups.flatMap(\.options).compactMap(\.format)
check("grupos usam capacidades declaradas", Set(formats) == ["jpg", "webp"])
check("grupos não reordenam entradas nem iniciam engine", center.jobs.map(\.input) == [second, first])

print("\n== commit radial com backend real (integração, sem simular drag global) ==")
let fixture = fixtureRoot.appendingPathComponent("metadata-fixture.png")
try makeMetadataPNGFixture(at: fixture)
check("fixture PNG é decodificável e contém metadata", imageProperties(fixture) != nil && pngAuthor(fixture) == "Garime RadialActions")

var realSubmitted: [TangerineJob] = []
var realDashboardPresented = false
let realController = TangerineController(
    engine: FileToolsBridge(),
    presentDashboard: { realDashboardPresented = true },
    onSubmitted: { realSubmitted = $0 }
)
realController.performSelectionAction(urls: [fixture], option: direct)
check("commit radial direto cria um job real", realSubmitted.count == 1)
check("commit radial simples não navega ao dashboard", !realDashboardPresented)
pump(15) { realSubmitted.first?.state != .running }
let realJob = realSubmitted.first
check("FileToolsBridge conclui o job", realJob?.state == .done, realJob?.message ?? "sem job")
let output = realJob?.outputs.first
check("backend materializa uma saída distinta", output != nil && output != fixture && fm.fileExists(atPath: output!.path), output?.path ?? "sem saída")
let outputProperties = output.flatMap(imageProperties)
check("saída continua sendo PNG válido 32×20",
      (outputProperties?[kCGImagePropertyPixelWidth] as? Int) == 32
        && (outputProperties?[kCGImagePropertyPixelHeight] as? Int) == 20,
      String(describing: outputProperties))
check("ação real remove a metadata da fixture", output.flatMap(pngAuthor) == nil, String(describing: output.flatMap(pngAuthor)))

print("\n== integração do controller: superfícies e permissão explícita ==")
var dashboardPresented = false
var compactPresented = false
var compactPresentedBeforeDropReturned = false
var dropReturned = false
let controller = TangerineController(
    engine: engine,
    presentDashboard: { dashboardPresented = true },
    presentCompactParameters: { _, _ in
        compactPresentedBeforeDropReturned = !dropReturned
        compactPresented = true
    }
)

controller.performSelectionAction(urls: [first], option: direct)
check("caminho simples não apresenta dashboard", !dashboardPresented)
check("caminho simples não apresenta editor compacto", !compactPresented)

controller.performSelectionAction(urls: [first], option: crop)
check("ação complexa não ativa UI antes de o drop retornar", !compactPresented && !dashboardPresented)
dropReturned = true
pump(0.2) { compactPresented }
check("ação complexa apresenta somente o editor compacto", compactPresented && !dashboardPresented)
check("editor compacto só é ativado depois do commit retornar", !compactPresentedBeforeDropReturned)

controller.showSettings()
check("dashboard permanece uma ação secundária explícita", dashboardPresented)

if failures == 0 {
    print("\n\(checks)/\(checks) checks passaram")
} else {
    print("\n\(failures) de \(checks) checks falharam")
    exit(1)
}
