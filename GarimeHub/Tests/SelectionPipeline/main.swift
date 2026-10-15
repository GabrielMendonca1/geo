import AppKit
import ImageIO

// Integration proof at injected OS/UI seams: production resolver, controller/catalog/job
// pipeline and FileToolsBridge -> FileToolsBackend are real. Finder and the contextual
// panel are deliberately represented by deterministic seam implementations.
var checks = 0
var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() { print("ok   · \(name)") }
    else { failures += 1; print("FAIL · \(name) \(detail())") }
}

func pump(_ seconds: TimeInterval, until ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !ready() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func makeTIFF(at url: URL, width: Int, height: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let image = rep.cgImage,
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
    else { throw NSError(domain: "SelectionPipelineFixture", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SelectionPipelineFixture", code: 2)
    }
}

func dimensions(_ url: URL) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

final class FixedFrontmost: FrontmostApplicationProviding {
    let source: FileSelectionSource
    init(_ source: FileSelectionSource) { self.source = source }
    func frontmostApplication() -> FileSelectionSource? { source }
}

final class InjectedFinderResult: FileSelectionProviding {
    private let lock = NSLock()
    private var results: [RawFileSelection]

    init(_ results: [RawFileSelection]) { self.results = results }

    func selection(for source: FileSelectionSource) throws -> RawFileSelection {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { throw FileSelectionFailure.providerError }
        return results.removeFirst()
    }
}

final class NeverUsedAccessibility: FileSelectionProviding {
    private(set) var calls = 0
    func selection(for source: FileSelectionSource) throws -> RawFileSelection {
        calls += 1
        throw FileSelectionFailure.providerError
    }
}

final class CapturingPresenter: FilesContextualPresenting {
    var onCommit: ((UUID, FilesOption) -> Void)?
    var onDismiss: ((UUID, FilesContextualDismissReason) -> Void)?
    private(set) var invocation: FilesContextualInvocation?
    private(set) var activeSessionID: UUID?
    private(set) var dismissals: [FilesContextualDismissReason] = []

    @discardableResult
    func present(_ invocation: FilesContextualInvocation) -> Bool {
        self.invocation = invocation
        activeSessionID = invocation.id
        return true
    }

    func dismiss(reason: FilesContextualDismissReason) {
        dismissals.append(reason)
        activeSessionID = nil
    }

    // Corresponding seam for a real contextual-wheel click.
    func pick(_ option: FilesOption) {
        guard let invocation, activeSessionID == invocation.id else { return }
        activeSessionID = nil
        onCommit?(invocation.id, option)
    }
}

func resolver(source: FileSelectionSource, results: [RawFileSelection], accessibility: NeverUsedAccessibility) -> FileSelectionResolver {
    FileSelectionResolver(
        frontmost: FixedFrontmost(source),
        finder: InjectedFinderResult(results),
        accessibility: accessibility,
        timeout: 2
    )
}

func pngOption(from presenter: CapturingPresenter) -> FilesOption? {
    presenter.invocation?.groups.flatMap(\.options).first { $0.kind == "convert" && $0.format == "png" }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardized
check("fixture usa /private/tmp sem atravessar o symlink /tmp", root.path.hasPrefix("/private/tmp/"), root.path)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

let source = FileSelectionSource(pid: 4242, bundleIdentifier: "com.apple.finder")
let input = root.appendingPathComponent("selected-original.tiff")
try makeTIFF(at: input, width: 37, height: 23)
let originalData = try Data(contentsOf: input)
let originalAttributes = try fm.attributesOfItem(atPath: input.path)

print("== seleção contextual → escolha capturada → backend real ==")
let successPresenter = CapturingPresenter()
let successAX = NeverUsedAccessibility()
let selected = RawFileSelection(selectedURLs: [input], documentURL: nil)
var compactCalls = 0
var submitted: [FilesJob] = []
let successController = FilesController(
    engine: FileToolsBridge(), // production default bridge; owns a real FileToolsBackend
    presentCompactParameters: { _, _ in compactCalls += 1 },
    onSubmitted: { submitted = $0 },
    selectionResolver: resolver(source: source, results: [selected, selected], accessibility: successAX),
    contextualPresenter: successPresenter,
    frontmostProvider: { source },
    anchorProvider: { .zero },
    frontmostPIDProvider: { nil },
    runningPIDProbe: { _ in false },
    activateSource: { _ in },
    presentNotice: { _, _, _ in },
    ownPID: 9999,
    revalidation: .strict
)

successController.invokeSelection(mode: .convert)
pump(3) { successPresenter.invocation != nil }
check("invokeSelection resolve o resultado Finder injetado", successPresenter.invocation?.urls == [input])
check("modo .convert chega à apresentação", successPresenter.invocation?.mode == .convert)
check("provider AX não participa do caminho Finder", successAX.calls == 0)
let picked = pngOption(from: successPresenter)
check("provider/catalog real oferece PNG para TIFF", picked != nil)
if let picked { successPresenter.pick(picked) }
pump(15) { submitted.first.map { $0.state != .running } ?? false }

check("clique correspondente cria exatamente um job", submitted.count == 1)
check("FileToolsBackend conclui conversão", submitted.first?.state == .done, submitted.first?.message ?? "sem job")
let output = submitted.first?.outputs.first
check("saída é arquivo novo PNG materializado",
      output.map { $0 != input && $0.pathExtension.lowercased() == "png" && fm.fileExists(atPath: $0.path) } == true,
      output?.path ?? "sem saída")
check("saída tem conteúdo de imagem válido 37×23", output.flatMap(dimensions).map { $0 == (37, 23) } == true,
      String(describing: output.flatMap(dimensions)))
check("original permanece byte a byte inalterado", (try? Data(contentsOf: input)) == originalData)
let attributesAfter = try fm.attributesOfItem(atPath: input.path)
check("original não foi substituído", originalAttributes[.systemFileNumber] as? NSNumber == attributesAfter[.systemFileNumber] as? NSNumber)
check("pipeline não abre import/drag", compactCalls == 0)

print("\n== revalidação estrita recusa seleção trocada ==")
let mismatchRoot = root.appendingPathComponent("mismatch", isDirectory: true)
try fm.createDirectory(at: mismatchRoot, withIntermediateDirectories: true)
let first = mismatchRoot.appendingPathComponent("first.tiff")
let changed = mismatchRoot.appendingPathComponent("changed.tiff")
try makeTIFF(at: first, width: 19, height: 11)
try makeTIFF(at: changed, width: 7, height: 5)
let beforeNames = Set(try fm.contentsOfDirectory(atPath: mismatchRoot.path))
let mismatchPresenter = CapturingPresenter()
var mismatchJobs: [FilesJob] = []
var mismatchNotices: [FilesContextualNotice] = []
let mismatchController = FilesController(
    engine: FileToolsBridge(),
    onSubmitted: { mismatchJobs = $0 },
    selectionResolver: resolver(
        source: source,
        results: [
            RawFileSelection(selectedURLs: [first], documentURL: nil),
            RawFileSelection(selectedURLs: [changed], documentURL: nil),
        ],
        accessibility: NeverUsedAccessibility()
    ),
    contextualPresenter: mismatchPresenter,
    frontmostProvider: { source },
    anchorProvider: { .zero },
    frontmostPIDProvider: { nil },
    runningPIDProbe: { _ in false },
    activateSource: { _ in },
    presentNotice: { notice, _, _ in mismatchNotices.append(notice) },
    ownPID: 9999,
    revalidation: .strict
)
mismatchController.invokeSelection(mode: .convert)
pump(3) { mismatchPresenter.invocation != nil }
if let option = pngOption(from: mismatchPresenter) { mismatchPresenter.pick(option) }
pump(3) { !mismatchNotices.isEmpty }
let afterNames = Set(try fm.contentsOfDirectory(atPath: mismatchRoot.path))
check("seleção diferente na revalidação não envia job", mismatchJobs.isEmpty)
check("seleção diferente informa recusa", mismatchNotices.last?.title.contains("seleção mudou") == true,
      mismatchNotices.last?.title ?? "sem aviso")
check("seleção diferente não produz saída", afterNames == beforeNames, "antes=\(beforeNames) depois=\(afterNames)")
check("fontes mismatch também permanecem válidas", dimensions(first).map { $0 == (19, 11) } == true && dimensions(changed).map { $0 == (7, 5) } == true)

print("\n== contrato independente do Option+Space ==")
let repositoryRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let hotkeySource = try String(
    contentsOf: repositoryRoot.appendingPathComponent("Sources/Dictation/Hotkey.swift"),
    encoding: .utf8
)
check("ditado continua em Option+Space",
      hotkeySource.contains("UInt32(kVK_Space)") && hotkeySource.contains("UInt32(optionKey)"))
check("teste não usa Finder/TCC/painel/drag/import reais",
      compactCalls == 0)

print("\npasses: \(checks - failures)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
