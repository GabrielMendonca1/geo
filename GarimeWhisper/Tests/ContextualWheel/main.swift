import AppKit

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
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let fixtureRoot: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("garime-contextual-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}()
try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

let uiSources = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : FileManager.default.currentDirectoryPath + "/Sources/FileTools/UI"

func fixture(_ name: String) -> URL {
    let url = fixtureRoot.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data([0x00, 0x01]))
    return url
}

let png = fixture("a.png")
let jpg = fixture("b.jpg")
let doc = fixture("c.pdf")

func session(_ count: Int, pid: pid_t = 501, id: UUID = UUID()) -> FilesContextualPolicy.Session {
    FilesContextualPolicy.Session(
        id: id,
        sourcePID: pid,
        fileKeys: ["/tmp/a.png"],
        optionCount: count
    )
}

var policy = FilesContextualPolicy()
let opened = session(4)
check("present limpa a seleção", policy.apply(.present(opened)) == [.select(nil)])
check("present não escolhe setor", policy.selection == nil)
check("enter sem setor não executa", policy.apply(.enter).isEmpty)
check("hover no vão não seleciona", policy.apply(.hover(nil)).isEmpty)
check("hover em setor seleciona", policy.apply(.hover(2)) == [.select(2)])
check("hover repetido não reemite", policy.apply(.hover(2)).isEmpty)
check("hover fora do alcance limpa", policy.apply(.hover(9)) == [.select(nil)])
check("seta próxima a partir do nada vai ao 0", policy.apply(.arrow(.next)) == [.select(0)])
check("seta anterior dá wrap para o último", policy.apply(.arrow(.previous)) == [.select(3)])
check("seta próxima dá wrap para o primeiro", policy.apply(.arrow(.next)) == [.select(0)])
let committed = policy.apply(.enter)
check("enter com setor executa a sessão", committed == [.commit(sessionID: opened.id, index: 0)])
check("enter depois do commit é no-op", policy.apply(.enter).isEmpty)
check("hover depois do commit é no-op", policy.apply(.hover(1)).isEmpty)

var clickPolicy = FilesContextualPolicy()
let clickSession = session(3)
_ = clickPolicy.apply(.present(clickSession))
check("clique no setor seleciona e executa",
      clickPolicy.apply(.click(1)) == [.select(1), .commit(sessionID: clickSession.id, index: 1)])
check("clique posterior não repete execução", clickPolicy.apply(.click(1)).isEmpty)

var gapPolicy = FilesContextualPolicy()
_ = gapPolicy.apply(.present(session(3)))
check("clique no vão/furo cancela", gapPolicy.apply(.click(nil)) == [.dismiss(.gap)])
check("depois do vão nada mais responde", gapPolicy.apply(.enter).isEmpty)

var escPolicy = FilesContextualPolicy()
_ = escPolicy.apply(.present(session(3)))
check("esc encerra", escPolicy.apply(.escape) == [.dismiss(.escape)])
check("esc repetido é no-op", escPolicy.apply(.escape).isEmpty)

var replacePolicy = FilesContextualPolicy()
let first = session(3, id: UUID())
let secondSession = session(5, pid: 777, id: UUID())
_ = replacePolicy.apply(.present(first))
_ = replacePolicy.apply(.hover(1))
_ = replacePolicy.apply(.present(secondSession))
check("nova invocação zera a seleção", replacePolicy.selection == nil)
check("nova invocação troca a sessão", replacePolicy.activeSessionID == secondSession.id)
_ = replacePolicy.apply(.hover(4))
check("commit carrega a sessão nova",
      replacePolicy.apply(.enter) == [.commit(sessionID: secondSession.id, index: 4)])

var emptyPolicy = FilesContextualPolicy()
check("sessão sem opções não apresenta",
      emptyPolicy.apply(.present(session(0))) == [.select(nil)])
check("sessão sem opções não fica ativa", emptyPolicy.isPresenting == false)

let finderSource = FileSelectionSource(pid: 300, bundleIdentifier: "com.apple.finder")
let otherSource = FileSelectionSource(pid: 400, bundleIdentifier: "com.acme.editor")
let finderDenied = FilesContextualNoticeFactory.notice(for: .permissionDenied, source: finderSource)
check("Finder sem permissão fala de Automação",
      finderDenied.remedy == .automation("com.apple.finder") && finderDenied.message.contains("Automação"),
      finderDenied.message)
let axDenied = FilesContextualNoticeFactory.notice(for: .permissionDenied, source: otherSource)
check("app comum sem permissão fala de Acessibilidade",
      axDenied.remedy == .accessibility && axDenied.message.contains("Acessibilidade"),
      axDenied.message)
check("erro sem remédio não oferece botão",
      FilesContextualNoticeFactory.notice(for: .timeout, source: finderSource).actionTitle == nil)
check("doc-only é falha explícita",
      FilesContextualNoticeFactory.documentOnlyNotice(source: otherSource).message.contains("documento aberto"))
check("seleção não suportada é explícita",
      FilesContextualNoticeFactory.notice(for: .unsupported, source: otherSource).title.contains("não suportada"))

check("foco volta quando o painel ficou à frente",
      FilesContextualFocus.shouldRestore(sourcePID: 300, frontmostPID: 999, ownPID: 999, sourceRunning: true))
check("foco não é roubado de outro app",
      !FilesContextualFocus.shouldRestore(sourcePID: 300, frontmostPID: 555, ownPID: 999, sourceRunning: true))
check("origem morta não é reativada",
      !FilesContextualFocus.shouldRestore(sourcePID: 300, frontmostPID: 999, ownPID: 999, sourceRunning: false))
check("ativação de terceiro invalida",
      FilesContextualFocus.shouldInvalidate(activatedPID: 555, sourcePID: 300, ownPID: 999))
check("ativação da própria origem não invalida",
      !FilesContextualFocus.shouldInvalidate(activatedPID: 300, sourcePID: 300, ownPID: 999))
check("ativação do próprio painel não invalida",
      !FilesContextualFocus.shouldInvalidate(activatedPID: 999, sourcePID: 300, ownPID: 999))

final class FakeSurface: NSView, FilesContextualSurface {
    var appliedGroups: [FilesGroup] = []
    var appliedFiles: [URL] = []
    var appliedMode: FilesMode = .convert
    var resets = 0
    var focusHistory: [Int?] = []
    var hits: [NSPoint: Int] = [:]
    private(set) var selectedIndex: Int?

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    var preferredSide: CGFloat { 320 }

    func prepare(forScreen screen: NSRect) {}

    var options: [FilesOption] { appliedGroups.flatMap(\.options) }

    var selectedOption: FilesOption? {
        guard let selectedIndex, options.indices.contains(selectedIndex) else { return nil }
        return options[selectedIndex]
    }

    func apply(groups: [FilesGroup], mode: FilesMode, headline: String, footnote: String) {
        appliedGroups = groups
        appliedMode = mode
    }

    func apply(fileURLs: [URL]) { appliedFiles = fileURLs }

    func reset() {
        resets += 1
        selectedIndex = nil
    }

    @discardableResult
    func track(at point: NSPoint) -> Bool {
        let index = hits[point]
        selectedIndex = index
        return index != nil
    }

    var contextualOptionCount: Int { options.count }

    func contextualHitIndex(at point: NSPoint) -> Int? { hits[point] }

    func contextualFocus(index: Int?) {
        focusHistory.append(index)
        selectedIndex = index
    }

    func contextualOption(at index: Int) -> FilesOption? {
        options.indices.contains(index) ? options[index] : nil
    }
}

let sampleOptions = [
    FilesOption(kind: "convert", format: "webp", title: "WEBP"),
    FilesOption(kind: "convert", format: "jpg", title: "JPG"),
    FilesOption(kind: "convert", format: "png", title: "PNG"),
]
let sampleGroups = [FilesGroup(title: "Converter", options: sampleOptions)]

var panelSurface: FakeSurface?
let panel = FilesContextualPanel(surfaceFactory: { frame in
    let surface = FakeSurface(frame: frame)
    panelSurface = surface
    return surface
})
let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
panel.screenProvider = { [screen] }
panel.fallbackScreen = { screen }
var panelCommits: [(UUID, FilesOption)] = []
var panelDismissals: [(UUID, FilesContextualDismissReason)] = []
panel.onCommit = { id, option in panelCommits.append((id, option)) }
panel.onDismiss = { id, reason in panelDismissals.append((id, reason)) }

let sectorPoint = NSPoint(x: 40, y: 40)
let gapPoint = NSPoint(x: 1, y: 1)
panelSurface?.hits = [sectorPoint: 1]

let invocation = FilesContextualInvocation(
    urls: [png, jpg],
    mode: .convert,
    sourcePID: 300,
    anchor: NSPoint(x: 700, y: 400),
    groups: sampleGroups,
    headline: "2 arquivos"
)
check("painel apresenta a invocação", panel.present(invocation))
check("painel recebe só as URLs da seleção", panelSurface?.appliedFiles == [png, jpg])
check("painel abre sem setor escolhido", panelSurface?.selectedOption == nil)
check("painel registra a sessão", panel.activeSessionID == invocation.id)
panel.handleHover(at: sectorPoint)
check("hover no setor seleciona", panelSurface?.selectedIndex == 1)
panel.handleHover(at: gapPoint)
check("hover no vão limpa", panelSurface?.selectedIndex == nil)
panel.handleKey(.arrow(.next))
check("seta seleciona o primeiro", panelSurface?.selectedIndex == 0)
panel.handleKey(.arrow(.previous))
check("seta anterior dá wrap", panelSurface?.selectedIndex == 2)
panel.handleKey(.escape)
check("esc encerra o painel", panel.activeSessionID == nil && !panel.isVisible)
check("esc informa o host", panelDismissals.last?.1 == .escape)
check("esc não executa nada", panelCommits.isEmpty)
check("painel limpa os arquivos ao fechar", panelSurface?.appliedFiles.isEmpty == true)

_ = panel.present(invocation)
panel.handleClick(at: gapPoint)
check("clique no vão cancela", panelDismissals.last?.1 == .gap && panelCommits.isEmpty)

let secondInvocation = FilesContextualInvocation(
    urls: [png],
    mode: .tools,
    sourcePID: 300,
    anchor: NSPoint(x: 700, y: 400),
    groups: sampleGroups,
    headline: "a.png"
)
_ = panel.present(secondInvocation)
panel.handleClick(at: sectorPoint)
check("clique no setor executa uma vez", panelCommits.count == 1)
check("execução carrega a sessão corrente", panelCommits.last?.0 == secondInvocation.id)
check("execução carrega a opção do setor", panelCommits.last?.1.id == sampleOptions[1].id)
check("painel fecha ao executar", !panel.isVisible)
panel.handleClick(at: sectorPoint)
check("clique depois de fechar não repete", panelCommits.count == 1)

let third = FilesContextualInvocation(
    urls: [jpg],
    mode: .convert,
    sourcePID: 300,
    anchor: NSPoint(x: 700, y: 400),
    groups: sampleGroups,
    headline: "b.jpg"
)
_ = panel.present(third)
let fourth = FilesContextualInvocation(
    urls: [png],
    mode: .convert,
    sourcePID: 301,
    anchor: NSPoint(x: 200, y: 200),
    groups: sampleGroups,
    headline: "a.png"
)
_ = panel.present(fourth)
check("reinvocação encerra a sessão anterior",
      panelDismissals.last?.0 == third.id && panelDismissals.last?.1 == .reinvoked)
check("reinvocação assume a sessão nova", panel.activeSessionID == fourth.id)
panel.dismiss(reason: .stopped)
check("stop fecha tudo", panel.activeSessionID == nil && !panel.isVisible)
check("apresentação sem grupos é recusada",
      !panel.present(FilesContextualInvocation(
          urls: [png],
          mode: .convert,
          sourcePID: 300,
          anchor: NSPoint(x: 10, y: 10),
          groups: [],
          headline: "a.png"
      )))

final class StubEngine: FilesRunning {
    var runs = 0
    func capability(for url: URL) -> FilesCapability { .unknown }
    func run(
        input: URL,
        option: FilesOption,
        values: [String: FilesValue],
        outputDirectory: URL?
    ) async throws -> FilesOutcome {
        runs += 1
        return FilesOutcome(outputs: [input], message: nil)
    }
}

final class FakeResolver: FilesSelectionResolving {
    var queued: [FileSelectionResolution] = []
    var deferred = false
    var pending: [(UUID, (FileSelectionResolution) -> Void)] = []
    private(set) var calls = 0

    @discardableResult
    func resolve(_ completion: @escaping (FileSelectionResolution) -> Void) -> UUID {
        calls += 1
        let id = UUID()
        let resolution = queued.isEmpty
            ? FileSelectionResolution.failed(requestID: id, source: nil, failure: .noSelection)
            : queued.removeFirst()
        if deferred {
            pending.append((id, completion))
            pendingResolutions[id] = resolution
        } else {
            completion(resolution)
        }
        return id
    }

    var pendingResolutions: [UUID: FileSelectionResolution] = [:]

    func flushFirst() {
        guard !pending.isEmpty else { return }
        let (id, completion) = pending.removeFirst()
        if let resolution = pendingResolutions.removeValue(forKey: id) { completion(resolution) }
    }
}

final class FakePresenter: FilesContextualPresenting {
    var onCommit: ((UUID, FilesOption) -> Void)?
    var onDismiss: ((UUID, FilesContextualDismissReason) -> Void)?
    var presented: [FilesContextualInvocation] = []
    var dismissals: [FilesContextualDismissReason] = []
    var accepts = true
    var activeSessionID: UUID?

    @discardableResult
    func present(_ invocation: FilesContextualInvocation) -> Bool {
        guard accepts else { return false }
        presented.append(invocation)
        activeSessionID = invocation.id
        return true
    }

    func dismiss(reason: FilesContextualDismissReason) {
        guard let id = activeSessionID else { return }
        dismissals.append(reason)
        activeSessionID = nil
        onDismiss?(id, reason)
    }
}

var dashboardCalls = 0
var notices: [FilesContextualNotice] = []
var noticeGrants: [(() -> Void)?] = []
var grants: [FilesContextualNotice.Remedy] = []
var submitted: [[FilesJob]] = []
var activations: [pid_t] = []

func makeController(
    resolver: FakeResolver,
    presenter: FakePresenter,
    engine: StubEngine,
    frontmost: FileSelectionSource?,
    frontmostPID: pid_t?,
    revalidation: FilesContextualRevalidation = .off,
    automation: Bool = false,
    accessibility: Bool = false
) -> FilesController {
    FilesController(
        engine: engine,
        presentDashboard: { dashboardCalls += 1 },
        onSubmitted: { submitted.append($0) },
        selectionResolver: resolver,
        contextualPresenter: presenter,
        frontmostProvider: { frontmost },
        anchorProvider: { NSPoint(x: 500, y: 500) },
        frontmostPIDProvider: { frontmostPID },
        runningPIDProbe: { _ in true },
        activateSource: { activations.append($0) },
        presentNotice: { notice, _, grant in
            notices.append(notice)
            noticeGrants.append(grant)
        },
        grantPermission: { grants.append($0) },
        automationPreflight: { automation },
        accessibilityPreflight: { accessibility },
        ownPID: 999,
        revalidation: revalidation
    )
}

func resolution(
    source: FileSelectionSource,
    selected: [URL],
    document: URL? = nil,
    failure: FileSelectionFailure? = nil,
    availability: FileSelectionAvailability? = .selected
) -> FileSelectionResolution {
    if let failure {
        return .failed(requestID: UUID(), source: source, failure: failure)
    }
    var candidates = selected.map { FileSelectionCandidate(kind: .selection, url: $0) }
    if let document { candidates.append(FileSelectionCandidate(kind: .document, url: document)) }
    return FileSelectionResolution(
        requestID: UUID(),
        source: source,
        candidates: candidates,
        selectionAvailability: availability,
        failure: nil
    )
}

let successResolver = FakeResolver()
let successPresenter = FakePresenter()
let successEngine = StubEngine()
let successController = makeController(
    resolver: successResolver,
    presenter: successPresenter,
    engine: successEngine,
    frontmost: finderSource,
    frontmostPID: 999
)
successResolver.queued = [resolution(source: finderSource, selected: [png, jpg], document: doc)]
successController.invokeSelection(mode: .convert)
check("invocação apresenta a roda uma vez", successPresenter.presented.count == 1)
check("apresenta só selectedURLs", successPresenter.presented.first?.urls == [png, jpg])
check("nunca abre o painel de ajustes", dashboardCalls == 0)
check("sucesso não emite erro", notices.isEmpty)
check("modo convert chega à roda", successPresenter.presented.first?.mode == .convert)
check("modo tools é respeitado", {
    successResolver.queued = [resolution(source: finderSource, selected: [png])]
    successController.invokeSelection(mode: .tools)
    return successPresenter.presented.last?.mode == .tools
}())
check("reinvocação invalida a anterior", successPresenter.dismissals.contains(.reinvoked))

let sessionID = successPresenter.presented.last?.id
successController.handleContextualCommit(sessionID: UUID(), option: sampleOptions[0])
check("commit de sessão velha não executa nada", submitted.isEmpty)
if let sessionID {
    successController.handleContextualCommit(sessionID: sessionID, option: sampleOptions[0])
}
pump(seconds: 0.4) { !submitted.isEmpty }
check("commit válido cria trabalho real", submitted.count == 1)
check("commit devolve foco à origem quando o painel estava à frente", activations == [300])
check("commit não abre o painel de ajustes", dashboardCalls == 0)

let docResolver = FakeResolver()
let docPresenter = FakePresenter()
let docController = makeController(
    resolver: docResolver,
    presenter: docPresenter,
    engine: StubEngine(),
    frontmost: otherSource,
    frontmostPID: 999
)
docResolver.queued = [resolution(source: otherSource, selected: [], document: doc, availability: .noSelection)]
notices.removeAll()
docController.invokeSelection(mode: .convert)
check("documento sem seleção não abre a roda", docPresenter.presented.isEmpty)
check("documento sem seleção explica a falha",
      notices.last?.message.contains("documento aberto") == true,
      notices.last?.message ?? "-")

let denyResolver = FakeResolver()
let denyPresenter = FakePresenter()
let denyController = makeController(
    resolver: denyResolver,
    presenter: denyPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999
)
denyResolver.queued = [resolution(source: finderSource, selected: [], failure: .permissionDenied)]
notices.removeAll()
noticeGrants.removeAll()
denyController.invokeSelection(mode: .convert)
check("permissão negada não abre a roda", denyPresenter.presented.isEmpty)
check("permissão do Finder aponta Automação", notices.last?.remedy == .automation("com.apple.finder"))
check("nenhuma permissão é pedida sozinha", grants.isEmpty)
noticeGrants.last??()
check("permissão só é pedida por ação explícita", grants == [.automation("com.apple.finder")])

let axResolver = FakeResolver()
let axPresenter = FakePresenter()
let axController = makeController(
    resolver: axResolver,
    presenter: axPresenter,
    engine: StubEngine(),
    frontmost: otherSource,
    frontmostPID: 999
)
axResolver.queued = [resolution(source: otherSource, selected: [], failure: .permissionDenied)]
notices.removeAll()
axController.invokeSelection(mode: .convert)
check("permissão fora do Finder aponta Acessibilidade", notices.last?.remedy == .accessibility)

let mismatchResolver = FakeResolver()
let mismatchPresenter = FakePresenter()
let mismatchController = makeController(
    resolver: mismatchResolver,
    presenter: mismatchPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999
)
mismatchResolver.queued = [resolution(source: otherSource, selected: [png])]
notices.removeAll()
mismatchController.invokeSelection(mode: .convert)
check("origem diferente da capturada não apresenta", mismatchPresenter.presented.isEmpty)
check("origem diferente vira erro explícito", notices.last?.title.contains("origem mudou") == true)

let staleResolver = FakeResolver()
let stalePresenter = FakePresenter()
let staleController = makeController(
    resolver: staleResolver,
    presenter: stalePresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999
)
staleResolver.deferred = true
staleResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: finderSource, selected: [jpg]),
]
staleController.invokeSelection(mode: .convert)
staleController.invokeSelection(mode: .convert)
staleResolver.flushFirst()
check("resposta atrasada da invocação antiga é ignorada", stalePresenter.presented.isEmpty)
staleResolver.flushFirst()
check("resposta da invocação corrente apresenta", stalePresenter.presented.map(\.urls) == [[jpg]])

let strictResolver = FakeResolver()
let strictPresenter = FakePresenter()
let strictController = makeController(
    resolver: strictResolver,
    presenter: strictPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999,
    revalidation: .strict
)
strictResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: finderSource, selected: [jpg]),
]
submitted.removeAll()
notices.removeAll()
strictController.invokeSelection(mode: .convert)
if let id = strictPresenter.presented.last?.id {
    strictController.handleContextualCommit(sessionID: id, option: sampleOptions[0])
}
pump(seconds: 0.3) { !notices.isEmpty }
check("seleção trocada no commit não vira trabalho", submitted.isEmpty)
check("seleção trocada explica a recusa", notices.last?.title.contains("seleção mudou") == true)

strictResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: finderSource, selected: [png]),
]
submitted.removeAll()
strictController.invokeSelection(mode: .convert)
if let id = strictPresenter.presented.last?.id {
    strictController.handleContextualCommit(sessionID: id, option: sampleOptions[0])
}
pump(seconds: 0.5) { !submitted.isEmpty }
check("seleção estável no commit vira trabalho", submitted.count == 1)

let activationResolver = FakeResolver()
let activationPresenter = FakePresenter()
let activationController = makeController(
    resolver: activationResolver,
    presenter: activationPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999
)
activationResolver.queued = [resolution(source: finderSource, selected: [png])]
activationController.invokeSelection(mode: .convert)
activationController.handleApplicationActivation(pid: 300)
check("ativação da própria origem mantém a roda", activationPresenter.dismissals.isEmpty)
activationController.handleApplicationActivation(pid: 999)
check("ativação do próprio painel mantém a roda", activationPresenter.dismissals.isEmpty)
activationController.handleApplicationActivation(pid: 555)
check("ativação de terceiro encerra a roda", activationPresenter.dismissals == [.sourceChanged])
check("sem sessão, nada mais é executado", activationController.contextualSelection.isEmpty)

let cancelResolver = FakeResolver()
let cancelPresenter = FakePresenter()
let cancelController = makeController(
    resolver: cancelResolver,
    presenter: cancelPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 555
)
cancelResolver.queued = [resolution(source: finderSource, selected: [png])]
activations.removeAll()
cancelController.invokeSelection(mode: .convert)
if let id = cancelPresenter.presented.last?.id {
    cancelController.handleContextualDismiss(sessionID: id, reason: .escape)
}
check("cancelamento com outro app à frente não rouba foco", activations.isEmpty)
check("cancelamento limpa a seleção", cancelController.contextualSelection.isEmpty)

let selfResolver = FakeResolver()
let selfPresenter = FakePresenter()
let selfController = makeController(
    resolver: selfResolver,
    presenter: selfPresenter,
    engine: StubEngine(),
    frontmost: FileSelectionSource(pid: 999, bundleIdentifier: "ai.garime.whisper"),
    frontmostPID: 999
)
notices.removeAll()
selfController.invokeSelection(mode: .convert)
check("invocação sobre o próprio app não abre a roda nem consulta seleção",
      selfPresenter.presented.isEmpty && selfResolver.calls == 0)
check("invocação sobre o próprio app avisa em vez de calar",
      notices.count == 1 && notices.last == FilesContextualNoticeFactory.ownApplicationNotice,
      notices.last?.title ?? "-")
check("aviso do próprio app manda voltar à origem sem remédio de TCC",
      notices.last?.remedy == FilesContextualNotice.Remedy.none
          && notices.last?.message.contains("app de origem") == true,
      notices.last?.message ?? "-")

let revalFailResolver = FakeResolver()
let revalFailPresenter = FakePresenter()
let revalFailController = makeController(
    resolver: revalFailResolver,
    presenter: revalFailPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999,
    revalidation: .strict
)
revalFailResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: finderSource, selected: [], failure: .timeout),
]
submitted.removeAll()
notices.removeAll()
revalFailController.invokeSelection(mode: .convert)
if let id = revalFailPresenter.presented.last?.id {
    revalFailController.handleContextualCommit(sessionID: id, option: sampleOptions[0])
}
pump(seconds: 0.3) { !notices.isEmpty }
check("falha na revalidação continua não executando", submitted.isEmpty)
check("falha na revalidação não mente dizendo que a seleção mudou",
      notices.last?.title.contains("seleção mudou") == false,
      notices.last?.title ?? "-")
check("timeout na revalidação fala da origem que não respondeu",
      notices.last?.title == FilesContextualNoticeFactory.notice(for: .timeout, source: finderSource).title,
      notices.last?.title ?? "-")
check("falha na revalidação diz que a ação não rodou",
      notices.last?.message.contains("não foi executada") == true,
      notices.last?.message ?? "-")

let revalDeniedResolver = FakeResolver()
let revalDeniedPresenter = FakePresenter()
let revalDeniedController = makeController(
    resolver: revalDeniedResolver,
    presenter: revalDeniedPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999,
    revalidation: .strict
)
revalDeniedResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: finderSource, selected: [], failure: .permissionDenied),
]
submitted.removeAll()
notices.removeAll()
revalDeniedController.invokeSelection(mode: .convert)
if let id = revalDeniedPresenter.presented.last?.id {
    revalDeniedController.handleContextualCommit(sessionID: id, option: sampleOptions[0])
}
pump(seconds: 0.3) { !notices.isEmpty }
check("permissão negada na revalidação mantém o remédio clicável",
      notices.last?.remedy == .automation("com.apple.finder") && submitted.isEmpty,
      notices.last?.title ?? "-")

let revalChangedResolver = FakeResolver()
let revalChangedPresenter = FakePresenter()
let revalChangedController = makeController(
    resolver: revalChangedResolver,
    presenter: revalChangedPresenter,
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999,
    revalidation: .strict
)
revalChangedResolver.queued = [
    resolution(source: finderSource, selected: [png]),
    resolution(source: otherSource, selected: [png]),
]
submitted.removeAll()
notices.removeAll()
revalChangedController.invokeSelection(mode: .convert)
if let id = revalChangedPresenter.presented.last?.id {
    revalChangedController.handleContextualCommit(sessionID: id, option: sampleOptions[0])
}
pump(seconds: 0.3) { !notices.isEmpty }
check("PID diferente na revalidação segue tratado como seleção mudada",
      notices.last?.title.contains("seleção mudou") == true && submitted.isEmpty,
      notices.last?.title ?? "-")

let noticePanel = FilesContextualNoticePanel()
check("botão do aviso aceita o primeiro clique com o app inativo", noticePanel.actionAcceptsFirstMouse)
check("botão do aviso começa escondido", !noticePanel.isActionVisible)
var noticeGrant = 0
noticePanel.show(
    FilesContextualNoticeFactory.permissionNotice(source: finderSource),
    at: NSPoint(x: 400, y: 400),
    onGrant: { noticeGrant += 1 }
)
check("aviso com remédio mostra o botão", noticePanel.isActionVisible)
check("botão visível continua aceitando o primeiro clique", noticePanel.actionAcceptsFirstMouse)
noticePanel.hide()
check("esconder o aviso não dispara a permissão", noticeGrant == 0)

let hoverRoot = FilesContextualRootView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
var hoverPoints: [NSPoint] = []
hoverRoot.onHover = { hoverPoints.append($0) }
if let moved = NSEvent.mouseEvent(
    with: .mouseMoved,
    location: NSPoint(x: 30, y: 40),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    eventNumber: 0,
    clickCount: 0,
    pressure: 0
) {
    hoverRoot.mouseMoved(with: moved)
}
check("mouseMoved real chega ao hover da roda", hoverPoints == [NSPoint(x: 30, y: 40)], "\(hoverPoints)")

var diagSurface: FakeSurface?
let diagPanel = FilesContextualPanel(surfaceFactory: { frame in
    let surface = FakeSurface(frame: frame)
    diagSurface = surface
    return surface
})
diagPanel.screenProvider = { [screen] }
diagPanel.fallbackScreen = { screen }
var diagLogs: [String] = []
diagPanel.diagnosticLog = { diagLogs.append($0) }
check("painel da roda pede eventos de mouse movido", diagPanel.tracksMouseMoved)
diagSurface?.hits = [sectorPoint: 1]
check("diagnóstico começa zerado", diagPanel.keyDiagnostics == FilesContextualKeyDiagnostics())
_ = diagPanel.present(FilesContextualInvocation(
    urls: [png],
    mode: .convert,
    sourcePID: 300,
    anchor: NSPoint(x: 700, y: 400),
    groups: sampleGroups,
    headline: "a.png"
))
check("diagnóstico conta a abertura", diagPanel.keyDiagnostics.presentations == 1)
diagPanel.handleKey(.arrow(.next))
diagPanel.handleKey(.escape)
check("diagnóstico conta as teclas entregues", diagPanel.keyDiagnostics.keysDelivered == 2)
check("fechamento sem key status fica registrado",
      diagPanel.keyDiagnostics.keyAcquisitions + diagPanel.keyDiagnostics.presentationsWithoutKey == 1,
      diagPanel.keyDiagnostics.summary)
check("diagnóstico de teclado é logado, não silencioso", diagLogs.count == 1, diagLogs.joined(separator: "|"))
check("resumo do diagnóstico é legível",
      diagPanel.keyboardDiagnosticSummary?.contains("aberturas 1") == true,
      diagPanel.keyboardDiagnosticSummary ?? "-")

let settingsController = makeController(
    resolver: FakeResolver(),
    presenter: FakePresenter(),
    engine: StubEngine(),
    frontmost: finderSource,
    frontmostPID: 999,
    automation: true
)
grants.removeAll()
check("ajustes de seleção mostram o estado real das permissões",
      settingsController.selectionSettingsSummary().contains("Automação (Finder): concedida")
          && settingsController.selectionSettingsSummary().contains("Acessibilidade (outros apps): pendente"))
settingsController.handleSelectionSettingsResponse(.alertThirdButtonReturn)
check("fechar os ajustes não pede permissão", grants.isEmpty)
settingsController.handleSelectionSettingsResponse(.alertFirstButtonReturn)
settingsController.handleSelectionSettingsResponse(.alertSecondButtonReturn)
check("botões dos ajustes pedem TCC por ação explícita",
      grants == [.automation("com.apple.finder"), .accessibility])
check("ajustes de seleção não abrem o dashboard", dashboardCalls == 0)

let sources = (try? FileManager.default.contentsOfDirectory(atPath: uiSources)) ?? []
let contextualSources = sources.filter { $0.hasPrefix("FilesContextual") }
check("os arquivos do fluxo contextual existem", contextualSources.count == 2, contextualSources.joined(separator: ","))
let contextualText = contextualSources
    .compactMap { try? String(contentsOfFile: uiSources + "/" + $0, encoding: .utf8) }
    .joined(separator: "\n")
check("fluxo contextual não registra hotkey",
      !contextualText.contains("RegisterEventHotKey") && !contextualText.contains("CGEvent.tapCreate"))
check("fluxo contextual não abre dashboard/ajustes",
      !contextualText.contains("FilesDashboard") && !contextualText.contains("showSettings"))
check("fluxo contextual não ativa o app à força",
      !contextualText.contains("NSApp.activate"))
let controllerText = (try? String(contentsOfFile: uiSources + "/FilesController.swift", encoding: .utf8)) ?? ""
check("controller expõe invokeSelection para o binding",
      controllerText.contains("public func invokeSelection(mode: FilesWheelMode"))
check("controller não registra atalho", !controllerText.contains("RegisterEventHotKey"))
check("revalidação estrita continua sendo o padrão",
      controllerText.contains("revalidation: FilesContextualRevalidation = .strict"))
check("diagnóstico de teclado não pede TCC global de teclado",
      !contextualText.contains("addGlobalMonitorForEvents")
          && !contextualText.contains("CGEventTap")
          && !controllerText.contains("addGlobalMonitorForEvents"))

print("")
print("\(checks - failures)/\(checks) verificações ok")
exit(failures == 0 ? 0 : 1)
