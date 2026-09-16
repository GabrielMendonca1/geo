import AppKit

// Testes de política/geometria/handshake do gesto da roda flutuante.
// Não são E2E: nenhum drag real do sistema é produzido, nenhum app é instalado,
// nenhuma permissão TCC é pedida ou contornada. O que passa aqui é contrato de código.

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

let sourceRoot: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/FileTools/UI", isDirectory: true)
}()

func source(_ name: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)) ?? ""
}

// MARK: - helpers

func sample(
    buttons: Int = 1,
    shift: Bool = true,
    option: Bool = false,
    at point: NSPoint = .zero,
    dragActive: Bool = false
) -> TangerineDragPolicy.Sample {
    var flags: NSEvent.ModifierFlags = []
    if shift { flags.insert(.shift) }
    if option { flags.insert(.option) }
    return TangerineDragPolicy.Sample(buttons: buttons, modifiers: flags, location: point, dragActive: dragActive)
}

// MARK: - 1. ativação do gesto

print("== 1. gesto: botão real + movimento + shift ==")

do {
    var policy = TangerineDragPolicy()
    check("shift sem botão não arma", policy.observe(sample(buttons: 0)).isEmpty && !policy.isArmed)
    check("botão sem shift não arma", policy.observe(sample(shift: false)).isEmpty && !policy.isArmed)
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(at: NSPoint(x: 100, y: 100)))
    let still = policy.observe(sample(at: NSPoint(x: 101, y: 100)))
    check("clique parado (sub-slop) não arma", still.isEmpty && !policy.isArmed)
    let moved = policy.observe(sample(at: NSPoint(x: 110, y: 100)))
    check("arma após movimento real acima do slop", moved == [.arm(at: NSPoint(x: 110, y: 100), mode: .convert)])
    check("estado armado", policy.isArmed && policy.mode == .convert)
    check("armado parado não reemite", policy.observe(sample(at: NSPoint(x: 110, y: 100))).isEmpty)
    check("armado seguindo o cursor emite follow (destino invisível acompanha)",
          policy.observe(sample(at: NSPoint(x: 120, y: 100))) == [.follow(at: NSPoint(x: 120, y: 100))])
    check("follow + troca de modo emitem na ordem",
          policy.observe(sample(option: true, at: NSPoint(x: 130, y: 100)))
            == [.follow(at: NSPoint(x: 130, y: 100)), .mode(.tools)])
}

do {
    var policy = TangerineDragPolicy()
    // shift apertado no meio de um drag que já está vivo: arma sem exigir novo slop
    let effects = policy.observe(sample(at: NSPoint(x: 40, y: 40), dragActive: true))
    check("drag vivo + shift arma imediatamente", effects == [.arm(at: NSPoint(x: 40, y: 40), mode: .convert)])
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(option: true, at: NSPoint(x: 0, y: 0), dragActive: true))
    check("⌥ no arm entra em tools", policy.mode == .tools)
    check("soltar ⌥ troca para convert", policy.observe(sample(dragActive: true)) == [.mode(.convert)])
    check("reapertar ⌥ volta para tools", policy.observe(sample(option: true, dragActive: true)) == [.mode(.tools)])
}

print("== 2. desarme: botão, shift, esc, fim de sessão ==")

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(dragActive: true))
    check("soltar botão desarma", policy.observe(sample(buttons: 0)) == [.disarm(.buttonReleased)])
    check("desarmado fica idle", !policy.isArmed)
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(dragActive: true))
    check("soltar shift desarma", policy.observe(sample(shift: false)) == [.disarm(.shiftReleased)])
    check("reapertar shift no mesmo drag rearma", policy.observe(sample(dragActive: true)).count == 1)
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(dragActive: true))
    check("esc desarma", policy.escape() == [.disarm(.escape)])
    check("após esc não rearma com botão ainda pressionado", policy.observe(sample(dragActive: true)).isEmpty)
    _ = policy.observe(sample(buttons: 0))
    check("novo drag após soltar botão rearma", policy.observe(sample(dragActive: true)).count == 1)
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(dragActive: true))
    check("drop trava até soltar botão", policy.dropPerformed() == [.disarm(.dropPerformed)])
    check("pós-drop não rearma", policy.observe(sample(dragActive: true)).isEmpty)
}

do {
    var policy = TangerineDragPolicy()
    _ = policy.observe(sample(dragActive: true))
    check("fim de sessão de drag desarma", policy.dragSessionEnded() == [.disarm(.dragEnded)])
    var idle = TangerineDragPolicy()
    check("desarme sem armar não emite efeito", idle.dragSessionEnded().isEmpty && idle.stop().isEmpty)
}

print("== 3. operação de drop ==")

do {
    var policy = TangerineDragPolicy()
    check("desarmado nunca aceita", policy.dropOperation(fileCount: 2, hasSector: true, shiftHeld: true) == [])
    _ = policy.observe(sample(dragActive: true))
    check("sem setor não retorna .copy", policy.dropOperation(fileCount: 2, hasSector: false, shiftHeld: true) == [])
    check("sem arquivos não retorna .copy", policy.dropOperation(fileCount: 0, hasSector: true, shiftHeld: true) == [])
    check("shift solto não retorna .copy", policy.dropOperation(fileCount: 2, hasSector: true, shiftHeld: false) == [])
    check("setor + arquivos + shift = .copy", policy.dropOperation(fileCount: 3, hasSector: true, shiftHeld: true) == .copy)
    check("accepts espelha a operação", policy.accepts(fileCount: 3, hasSector: true, shiftHeld: true)
        && !policy.accepts(fileCount: 3, hasSector: false, shiftHeld: true))
}

print("== 4. backend de eventos e permissão (Input Monitoring) ==")

check("com Input Monitoring usa monitores de NSEvent",
      TangerineGestureBackend.resolve(inputMonitoring: true) == .eventMonitor)
check("sem Input Monitoring cai no polling",
      TangerineGestureBackend.resolve(inputMonitoring: false) == .polling)
check("esc só é detectável no backend de monitor",
      TangerineGestureBackend.eventMonitor.detectsEscape && !TangerineGestureBackend.polling.detectsEscape)
check("polling armado é mais rápido que ocioso",
      TangerineGestureBackend.polling.pollInterval(armed: true) < TangerineGestureBackend.polling.pollInterval(armed: false))

do {
    let saved = TangerineInputMonitoring.preflight
    defer { TangerineInputMonitoring.preflight = saved }
    TangerineInputMonitoring.preflight = { false }
    check("permissão ausente é detectada como .unavailable",
          TangerineInputMonitoring.status == .unavailable && !TangerineInputMonitoring.isAvailable)
    let unavailable = TangerineGestureBackend.resolve(inputMonitoring: false)
        .status(inputMonitoring: .unavailable)
    check("status sem permissão = polling, Esc não detectável",
          unavailable.backend == .polling && !unavailable.detectsEscape)
    check("status nunca afirma que cross-app funciona (não verificado)",
          unavailable.crossAppVerified == false && unavailable.summary.contains("não verificado"))
    TangerineInputMonitoring.preflight = { true }
    check("permissão concedida é detectada como .granted", TangerineInputMonitoring.status == .granted)
    let granted = TangerineGestureBackend.resolve(inputMonitoring: true).status(inputMonitoring: .granted)
    check("status com permissão = monitores + Esc", granted.backend == .eventMonitor && granted.detectsEscape)
    check("mesmo com permissão, cross-app segue não verificado", granted.crossAppVerified == false)
}

do {
    // O monitor escolhe o backend pelo status injetado e nunca pede permissão sozinho.
    let monitor = TangerineDragMonitor()
    monitor.inputMonitoringProbe = { .unavailable }
    monitor.start()
    check("monitor sem permissão roda em polling", monitor.backend == .polling)
    check("monitor expõe o status da permissão", monitor.inputMonitoring == .unavailable
        && monitor.status.backend == .polling && monitor.status.crossAppVerified == false)
    monitor.stop()
}

let policyFileSource = source("TangerineDragPolicy.swift")
let overlayFileSource = source("FinderDragOverlay.swift")
check("preflight vive no arquivo de policy (consulta, nunca prompt)",
      policyFileSource.contains("CGPreflightListenEventAccess"))
check("request existe como função explícita de ação do usuário",
      policyFileSource.contains("static func requestFromUserAction")
        && policyFileSource.contains("CGRequestListenEventAccess"))
check("request é a única ocorrência de CGRequest* (uma chamada, dentro da função explícita)",
      policyFileSource.components(separatedBy: "CGRequestListenEventAccess").count == 2)
check("overlay nunca chama CGRequest* nem prompt de acessibilidade",
      !overlayFileSource.contains("CGRequestListenEventAccess")
        && !overlayFileSource.contains("AXIsProcessTrustedWithOptions"))
check("nenhum caminho automático pede permissão (start/timer não chamam request)",
      overlayFileSource.components(separatedBy: "requestFromUserAction").count == 2
        && overlayFileSource.contains("func requestInputMonitoringFromUserAction"))

print("== 5. geometria: telas negativas, bordas, Retina, sem tela sob o cursor ==")

let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
let left = NSRect(x: -1920, y: -300, width: 1920, height: 1080)
let screens = [main, left]

check("escolhe a tela que contém o cursor",
      TangerineWheelPlacement.screen(containing: NSPoint(x: -1000, y: 200), screens: screens, fallback: nil) == left)
check("origem negativa é respeitada",
      TangerineWheelPlacement.screen(containing: NSPoint(x: -1900, y: -290), screens: screens, fallback: nil) == left)
check("cursor fora de qualquer tela cai na mais próxima",
      TangerineWheelPlacement.screen(containing: NSPoint(x: 5000, y: 5000), screens: screens, fallback: nil) == main)
check("sem telas usa fallback",
      TangerineWheelPlacement.screen(containing: .zero, screens: [], fallback: main) == main)

do {
    let frame = TangerineWheelPlacement.frame(center: NSPoint(x: 700, y: 500), side: 400, screen: main)
    check("centrado no cursor quando cabe", frame == NSRect(x: 500, y: 300, width: 400, height: 400))
}
do {
    let frame = TangerineWheelPlacement.frame(center: NSPoint(x: 2, y: 2), side: 400, screen: main)
    check("gruda na borda inferior-esquerda com margem", frame.minX == 6 && frame.minY == 6)
}
do {
    let frame = TangerineWheelPlacement.frame(center: NSPoint(x: 1439, y: 899), side: 400, screen: main)
    check("gruda na borda superior-direita", frame.maxX == main.maxX - 6 && frame.maxY == main.maxY - 6)
}
do {
    let frame = TangerineWheelPlacement.frame(center: NSPoint(x: -1910, y: -295), side: 400, screen: left)
    check("clampa dentro de tela com origem negativa",
          left.contains(frame), "\(frame) fora de \(left)")
}
do {
    // Retina/pontos: o placement é em pontos; tela menor que a roda → centraliza sem sair.
    let tiny = NSRect(x: 0, y: 0, width: 320, height: 200)
    let frame = TangerineWheelPlacement.frame(center: NSPoint(x: 10, y: 10), side: 400, screen: tiny)
    check("tela menor que a roda centraliza (sem NaN/inversão)",
          frame.midX == tiny.midX && frame.midY == tiny.midY && frame.width == 400)
}

print("== 6. superfície: contrato do protocolo e fábrica estática ==")

final class FakeWheel: NSView, TangerineWheelSurface {
    static var made = 0
    var sectorAt: NSPoint?
    var option: TangerineOption?
    private(set) var applied: [(groups: [TangerineGroup], mode: TangerineMode, headline: String)] = []
    private(set) var resets = 0

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        FakeWheel.made += 1
    }

    required init?(coder: NSCoder) { nil }

    var preferredSide: CGFloat { preparedScreen.map { min($0.width, $0.height) * 0.4 } ?? 360 }
    var selectedOption: TangerineOption? { option }
    private(set) var preparedScreen: NSRect?

    func prepare(forScreen screen: NSRect) {
        preparedScreen = screen
    }

    private(set) var files: [[URL]] = []

    func apply(groups: [TangerineGroup], mode: TangerineMode, headline: String, footnote: String) {
        applied.append((groups, mode, headline))
    }

    func apply(fileURLs: [URL]) {
        files.append(fileURLs)
    }

    func reset() {
        resets += 1
        option = nil
    }

    @discardableResult
    func track(at point: NSPoint) -> Bool {
        guard let sectorAt, hypot(point.x - sectorAt.x, point.y - sectorAt.y) < 30 else {
            option = nil
            return false
        }
        option = TangerineOption(kind: "convert", format: "png", title: "PNG")
        return true
    }
}

var lastFake: FakeWheel?
TangerineWheelSurfaceFactory.override = { frame in
    let wheel = FakeWheel(frame: frame)
    lastFake = wheel
    return wheel
}

do {
    let saved = TangerineWheelSurfaceFactory.override
    TangerineWheelSurfaceFactory.override = nil
    let made = TangerineWheelSurfaceFactory.make(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    check("fábrica padrão é estática: sempre FloatingRadialView", made is FloatingRadialView)
    check("fábrica padrão nunca devolve a roda do dashboard", !(made is RadialMenuView))
    made.reset()
    check("FloatingRadialView real: reset sem setor", made.selectedOption == nil)
    check("FloatingRadialView real: preferredSide > 0", made.preferredSide > 0)
    TangerineWheelSurfaceFactory.override = saved
}

check("sem lookup dinâmico de classe (fábrica é estática)",
      !source("TangerineDragPolicy.swift").contains("NSClassFromString"))
check("sem fallback para a roda aninhada do dashboard",
      !source("TangerineDragPolicy.swift").contains("TangerineFallbackWheel")
        && !source("FinderDragOverlay.swift").contains("RadialMenuView"))
check("protocolo expõe os metadados do arquivo arrastado",
      source("TangerineDragPolicy.swift").contains("func apply(fileURLs: [URL])"))

print("== 7. handshake real de NSDraggingInfo ==")

final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: NSPoint

    init(urls: [URL], location: NSPoint) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("garime.radial.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        self.location = location
        super.init()
    }

    /// Drag que **não** é de arquivo (texto selecionado, item de app).
    init(text: String, location: NSPoint) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("garime.radial.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        self.location = location
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

let fixtures = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("garime-radial-gesture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
func fixture(_ name: String) -> URL {
    let url = fixtures.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data([0, 1]))
    return url
}
let files = [fixture("a.png"), fixture("b.png"), fixture("c.jpg")]

let group = TangerineGroup(title: "Imagens", options: [
    TangerineOption(kind: "convert", format: "png", title: "PNG"),
])

var shift = true
var option = false
let overlay = FinderDragOverlay()
var committed: [([URL], TangerineOption)] = []
overlay.provideGroups = { urls, mode in (groups: [group], headline: "\(urls.count) arquivos · \(mode.title)") }
overlay.commit = { urls, opt in committed.append((urls, opt)) }
overlay.modifierProvider = {
    var flags: NSEvent.ModifierFlags = []
    if shift { flags.insert(.shift) }
    if option { flags.insert(.option) }
    return flags
}
overlay.screenProvider = { [main] }
overlay.dragScreenPoint = { _ in NSPoint(x: 400, y: 400) }

check("overlay usa a superfície injetada (sem RadialMenuView direto)", lastFake != nil)

let sectorPoint = NSPoint(x: 300, y: 120)
let fake = lastFake

// sem armar, um drag que chega não deve ser aceito
do {
    let info = FakeDraggingInfo(urls: files, location: sectorPoint)
    check("drag antes do gesto: nenhuma operação", overlay.handleEntered(info) == [])
    check("drag antes do gesto: nada visível", overlay.isVisible == false)
}

// gesto arma via policy → overlay mostra roda perto do cursor
overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
check("arm arma o destino (painel minúsculo, transparente)", overlay.isVisible)
check("arm não mostra roda nenhuma antes do handshake", overlay.isWheelVisible == false)

// drag que não é de arquivo: nada aparece e o drop não é engolido
do {
    let text = FakeDraggingInfo(text: "seleção de texto", location: NSPoint(x: 10, y: 10))
    let before = fake?.applied.count ?? 0
    check("drag sem file URL não é aceito (destino real segue dono)", overlay.handleEntered(text) == [])
    check("drag sem file URL não revela a roda", overlay.isWheelVisible == false)
    check("drag sem file URL não aplica grupos", (fake?.applied.count ?? 0) == before)
    check("drag sem file URL não é aceito no prepare/perform",
          overlay.handleAccept(text) == false && overlay.handlePerform(text) == false)
}

do {
    fake?.sectorAt = nil
    let info = FakeDraggingInfo(urls: files, location: NSPoint(x: 10, y: 10))
    let op = overlay.handleEntered(info)
    check("entered lê os fileURLs do NSDraggingInfo (array)", overlay.urls.count == 3)
    check("URL real revela a roda", overlay.isWheelVisible)
    check("roda é dimensionada para a tela do cursor antes do reveal", fake?.preparedScreen == main)
    check("metadados do arquivo chegam à superfície", fake?.files.last?.count == 3)
    check("entered fora de setor não retorna .copy", op == [])
    check("grupos foram aplicados na superfície", (fake?.applied.count ?? 0) >= 1)
    check("drop no furo/vão/canto é cancelamento explícito (AppKit não tem pass-through)",
          overlay.handleAccept(info) == false && overlay.lastDropDecision == .cancel)
    check("cancelamento esconde a roda e encerra o gesto", overlay.isVisible == false)
    check("performDragOperation recusa sem setor", overlay.handlePerform(info) == false)
    check("nenhum commit sem setor", committed.isEmpty)
}

do {
    overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
    fake?.sectorAt = sectorPoint
    _ = overlay.handleEntered(FakeDraggingInfo(urls: files, location: sectorPoint))
    let info = FakeDraggingInfo(urls: files, location: sectorPoint)
    check("updated em setor válido retorna .copy", overlay.handleUpdated(info) == .copy)
    check("aceita o drop em setor válido", overlay.handleAccept(info))
    check("decisão registrada é perform", overlay.lastDropDecision == .perform)
    check("perform entrega o array inteiro", overlay.handlePerform(info) && committed.first?.0.count == 3)
    check("opção entregue é a do setor", committed.first?.1.format == "png")
    check("drop esconde a roda (sem dashboard)", overlay.isVisible == false)
}

// shift solto durante o drag: nada é aceito
do {
    committed.removeAll()
    overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
    fake?.sectorAt = sectorPoint
    let armedInfo = FakeDraggingInfo(urls: files, location: sectorPoint)
    _ = overlay.handleEntered(armedInfo)
    shift = false
    check("shift solto: updated não retorna .copy", overlay.handleUpdated(armedInfo) == [])
    check("shift solto esconde o painel antes de seguir o drag normal",
          overlay.isVisible == false && overlay.isWheelVisible == false)
    check("shift solto: prepare recusa", overlay.handleAccept(armedInfo) == false)
    check("shift solto: perform recusa", overlay.handlePerform(armedInfo) == false && committed.isEmpty)
    shift = true
}

// desarme esconde e limpa estado (sem pasteboard preso)
do {
    overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
    let info = FakeDraggingInfo(urls: files, location: sectorPoint)
    _ = overlay.handleEntered(info)
    check("urls presentes durante o drag", overlay.urls.isEmpty == false)
    overlay.apply([.disarm(.escape)])
    check("esc esconde", overlay.isVisible == false)
    check("esc limpa as urls (nada de pasteboard velho)", overlay.urls.isEmpty)
    let after = FakeDraggingInfo(urls: files, location: sectorPoint)
    check("após esc um drag que passa não é aceito", overlay.handleEntered(after) == [] && overlay.handleAccept(after) == false)
}

// ⌥ troca o modo com as mesmas urls
do {
    overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
    let info = FakeDraggingInfo(urls: files, location: sectorPoint)
    _ = overlay.handleEntered(info)
    let before = fake?.applied.count ?? 0
    option = true
    _ = overlay.handleUpdated(info)
    check("⌥ durante o drag reaplica grupos no modo tools",
          (fake?.applied.count ?? 0) > before && fake?.applied.last?.mode == .tools)
    option = false
    _ = overlay.handleUpdated(info)
    check("soltar ⌥ volta para convert", fake?.applied.last?.mode == .convert)
    overlay.apply([.disarm(.buttonReleased)])
}

// drop fora da roda: exited não esconde, mas zera seleção
do {
    overlay.apply([.arm(at: NSPoint(x: 400, y: 400), mode: .convert)])
    let info = FakeDraggingInfo(urls: files, location: sectorPoint)
    fake?.sectorAt = sectorPoint
    _ = overlay.handleEntered(info)
    let resets = fake?.resets ?? 0
    overlay.handleExited()
    check("sair da roda zera a seleção", (fake?.resets ?? 0) > resets)
    check("sair da roda não esconde (destino real segue dono do drop)", overlay.isVisible)
    check("seleção zerada impede .copy", overlay.handleAccept(FakeDraggingInfo(urls: files, location: NSPoint(x: 5, y: 5))) == false)
    overlay.apply([.disarm(.dragEnded)])
}

print("== 8. respeito ao sistema (fonte) ==")

let overlaySource = source("FinderDragOverlay.swift")
let policySource = source("TangerineDragPolicy.swift")

check("fonte do overlay foi lida", !overlaySource.isEmpty && !policySource.isEmpty)
check("nenhuma ativação de app", !overlaySource.contains("NSApp.activate") && !overlaySource.contains("makeKeyAndOrderFront"))
check("painel não ativante", overlaySource.contains(".nonactivatingPanel") && overlaySource.contains("becomesKeyOnlyIfNeeded"))
check("aparece em qualquer Space", overlaySource.contains("canJoinAllSpaces") && overlaySource.contains("orderFrontRegardless"))
check("sem gate de app frontal (cross-app, inclui desktop do Finder)",
      !overlaySource.contains("frontmostApplication") && !overlaySource.contains("com.apple.finder"))
check("registra apenas .fileURL como tipo de drag", overlaySource.contains("registerForDraggedTypes([.fileURL])"))
check("URLs vêm do draggingPasteboard do NSDraggingInfo", overlaySource.contains("info.draggingPasteboard"))
check("não escreve no pasteboard geral", !overlaySource.contains("NSPasteboard.general"))
check("nenhuma escrita em disco no overlay",
      !overlaySource.contains("FileManager.default.createFile") && !overlaySource.contains("write(to:"))
check("painel é do tamanho da roda, não fullscreen",
      overlaySource.contains("surface.preferredSide") && !overlaySource.contains("screen.frame\n"))
check("dashboard não é aberto pelo gesto",
      !overlaySource.contains("TangerineDashboard") && !overlaySource.contains("present("))
check("policy não lê pasteboard", !policySource.contains("NSPasteboard"))
check("destino candidato é minúsculo e transparente (não engole drag alheio)",
      overlaySource.contains("static let probeSide") && overlaySource.contains("surface.isHidden = true"))

print("== 9. wiring de produção: FloatingRadialView real, sem mock ==")

TangerineWheelSurfaceFactory.override = nil

do {
    let live = FinderDragOverlay()
    var liveShift = true
    var liveCommitted: [([URL], TangerineOption)] = []
    live.modifierProvider = { liveShift ? .shift : [] }
    live.screenProvider = { [main] }
    live.dragScreenPoint = { _ in NSPoint(x: 700, y: 500) }
    live.provideGroups = { urls, mode in
        let groups = mode == .convert
            ? TangerineCatalog.convertGroups(category: .images, sourceExtension: "png")
            : TangerineCatalog.toolGroups(category: .images)
        guard !groups.isEmpty else { return nil }
        return (groups, TangerineDraggedFile.displayName(urls))
    }
    live.commit = { urls, option in liveCommitted.append((urls, option)) }

    let view = live.wheel as? FloatingRadialView
    check("overlay de produção instancia a FloatingRadialView (fábrica estática)", view != nil)

    if let view {
        live.apply([.arm(at: NSPoint(x: 300, y: 300), mode: .convert)])
        check("candidato: destino armado, roda ainda invisível",
              live.isVisible && live.isWheelVisible == false && view.isHidden)
        check("candidato: furo sem nome/ícone antes de URL real",
              view.fileName.isEmpty && view.fileIcon == nil && view.options.isEmpty)

        // cursor anda antes do handshake: o destino segue, nada é desenhado
        live.apply([.follow(at: NSPoint(x: 500, y: 420))])
        check("follow não revela a roda", live.isWheelVisible == false && view.isHidden)

        let single = [files[0]]
        let entered = FakeDraggingInfo(urls: single, location: NSPoint(x: 4, y: 4))
        let op = live.handleEntered(entered)
        view.layoutSubtreeIfNeeded()
        check("handshake real revela a roda", live.isWheelVisible && !view.isHidden)
        check("frame do reveal não retorna .copy (sem setor confiável)", op == [])
        check("nome do arquivo real chega ao furo central", view.fileName == files[0].lastPathComponent,
              "fileName=\(view.fileName)")
        check("ícone real do arquivo chega ao furo central", view.fileIcon != nil)
        check("opções do catálogo real populam a roda", view.options.count >= 2)
        check("nenhum setor pré-selecionado", view.selectedOption == nil)
        check("diâmetro do reveal é o desejado para a tela (não o herdado do probe de 24pt)",
              view.diameter == FloatingRadialView.preferredDiameter(screenFrame: main),
              "diameter=\(view.diameter) esperado=\(FloatingRadialView.preferredDiameter(screenFrame: main))")
        check("diâmetro do reveal é maior que o mínimo de layout (prova que não colapsou)",
              view.diameter > FloatingRadialView.minDiameter)

        if let mid = view.sectorMidpoint(0) {
            let expected = view.options[0]
            let onSector = FakeDraggingInfo(urls: single, location: mid)
            check("updated sobre setor real retorna .copy", live.handleUpdated(onSector) == .copy)
            check("seleção real segue o ponteiro", view.selectedOption?.id == expected.id)
            check("prepare aceita sobre setor real", live.handleAccept(onSector))
            check("perform entrega URLs reais ao commit", live.handlePerform(onSector))
            check("commit recebeu o arquivo e a opção do setor",
                  liveCommitted.count == 1
                    && liveCommitted[0].0 == single
                    && liveCommitted[0].1.id == expected.id)
        } else {
            check("roda real tem setor 0", false)
        }

        check("drop esconde tudo e limpa o furo",
              live.isVisible == false && live.isWheelVisible == false
                && view.isHidden && view.fileName.isEmpty && view.fileIcon == nil)
        check("hide limpa as opções (nenhuma roda velha sobrevive ao drag)", view.options.isEmpty)

        // segundo drag: o tamanho não depende do ciclo de layout anterior
        live.apply([.arm(at: NSPoint(x: 300, y: 300), mode: .convert)])
        view.layoutSubtreeIfNeeded()
        _ = live.handleEntered(FakeDraggingInfo(urls: single, location: NSPoint(x: 4, y: 4)))
        view.layoutSubtreeIfNeeded()
        check("segundo drag tem exatamente o mesmo diâmetro (determinístico)",
              view.diameter == FloatingRadialView.preferredDiameter(screenFrame: main),
              "diameter=\(view.diameter)")

        // drop no furo central: cancelamento explícito, nunca promessa de pass-through
        let inHole = FakeDraggingInfo(urls: single, location: view.centerCoordinates())
        check("furo central não seleciona setor", live.handleUpdated(inHole) == [])
        check("drop no furo cancela (AppKit não reencaminha para o destino de baixo)",
              live.handleAccept(inHole) == false && live.lastDropDecision == .cancel)
        check("cancelamento tira a roda da tela e não executa nada",
              live.isVisible == false && view.isHidden && liveCommitted.count == 1)
        liveCommitted.removeAll()

        // shift solto no meio do drag real: nada é aceito
        liveCommitted.removeAll()
        live.apply([.arm(at: NSPoint(x: 300, y: 300), mode: .convert)])
        let again = FakeDraggingInfo(urls: single, location: NSPoint(x: 4, y: 4))
        _ = live.handleEntered(again)
        liveShift = false
        let mid = view.sectorMidpoint(0) ?? .zero
        let afterShift = FakeDraggingInfo(urls: single, location: mid)
        check("shift solto no wiring real: nada aceito",
              live.handleUpdated(afterShift) == [] && live.handleAccept(afterShift) == false
                && live.handlePerform(afterShift) == false && liveCommitted.isEmpty)
        check("shift solto já escondeu o painel no primeiro updated (drag normal segue)",
              live.isVisible == false && live.isWheelVisible == false && view.isHidden)
        liveShift = true
        live.apply([.disarm(.dragEnded)])
        check("disarm esconde a roda real", live.isWheelVisible == false && view.isHidden)

        // drag não-arquivo no overlay de produção
        live.apply([.arm(at: NSPoint(x: 300, y: 300), mode: .convert)])
        let text = FakeDraggingInfo(text: "não sou arquivo", location: NSPoint(x: 4, y: 4))
        check("produção: drag não-arquivo não é engolido nem desenha",
              live.handleEntered(text) == [] && live.isWheelVisible == false && view.isHidden)
        live.apply([.disarm(.dragEnded)])
    }
}

print("== 10. monitor real: Esc, shift e permissão ==")

do {
    let monitor = TangerineDragMonitor()
    monitor.inputMonitoringProbe = { .unavailable }
    var effects: [TangerineDragPolicy.Effect] = []
    monitor.onEffects = { effects.append(contentsOf: $0) }
    monitor.start()
    check("monitor sem TCC entra em polling e não promete Esc",
          monitor.backend == .polling && monitor.status.detectsEscape == false)

    monitor.feed(sample(at: NSPoint(x: 10, y: 10), dragActive: true))
    check("monitor arma a partir de amostra real", monitor.isArmed)

    effects.removeAll()
    monitor.noteEscape()
    check("Esc pelo monitor desarma de verdade", effects == [.disarm(.escape)] && !monitor.isArmed)
    effects.removeAll()
    monitor.feed(sample(at: NSPoint(x: 11, y: 10), dragActive: true))
    check("pós-Esc não rearma com botão ainda preso", effects.isEmpty && !monitor.isArmed)
    monitor.feed(sample(buttons: 0, at: NSPoint(x: 11, y: 10)))
    monitor.feed(sample(at: NSPoint(x: 20, y: 20), dragActive: true))
    check("soltar o botão libera o lock do Esc", monitor.isArmed)

    effects.removeAll()
    monitor.feed(sample(shift: false, at: NSPoint(x: 20, y: 20), dragActive: true))
    check("soltar shift desarma no monitor", effects == [.disarm(.shiftReleased)] && !monitor.isArmed)
    monitor.stop()
    check("stop desarma e não deixa estado preso", !monitor.isArmed)
}

check("Esc também tem monitor local (sem TCC) além do global",
      overlaySource.contains("addLocalMonitorForEvents")
        && overlaySource.contains("addGlobalMonitorForEvents")
        && overlaySource.contains("escapeKeyCode"))

print("== 11. amostragem real do pump: memória de drag vivo não vaza ==")

do {
    // Seam de amostragem: entrada bruta injetada + `pump()` real (o único lugar que lê sawRealDrag).
    let monitor = TangerineDragMonitor()
    monitor.inputMonitoringProbe = { .unavailable }
    var raw = TangerineDragMonitor.RawInput(buttons: 1, modifiers: .shift, location: NSPoint(x: 100, y: 100))
    monitor.rawInput = { raw }
    monitor.start()

    monitor.pumpOnce()
    check("pump real: ⇧+botão parado não arma (slop vale)", !monitor.isArmed)
    monitor.noteLiveDragSession()
    check("handshake marca sessão de drag viva", monitor.hasLiveDragSession)
    monitor.pumpOnce()
    check("pump real arma com drag vivo", monitor.isArmed)

    monitor.noteDropPerformed()
    check("drop zera a memória de drag vivo", !monitor.hasLiveDragSession && !monitor.isArmed)

    raw.buttons = 0
    monitor.pumpOnce()
    raw.buttons = 1
    monitor.pumpOnce()
    check("pós-drop: novo ⇧+clique parado não arma (slop de volta)", !monitor.isArmed)
    raw.location = NSPoint(x: 102, y: 100)
    monitor.pumpOnce()
    check("pós-drop: movimento sub-slop continua sem armar", !monitor.isArmed)
    raw.location = NSPoint(x: 120, y: 100)
    monitor.pumpOnce()
    check("pós-drop: só movimento real acima do slop arma", monitor.isArmed)

    monitor.noteLiveDragSession()
    raw.buttons = 0
    monitor.pumpOnce()
    check("botão solto amostrado zera a memória de drag vivo",
          !monitor.hasLiveDragSession && !monitor.isArmed)
    raw.buttons = 1
    monitor.pumpOnce()
    check("depois do mouse up, ⇧+clique parado não arma", !monitor.isArmed)

    monitor.noteLiveDragSession()
    monitor.noteDragSessionEnded()
    check("fim de sessão também zera a memória", !monitor.hasLiveDragSession)
    monitor.clearLiveDragSession()
    monitor.stop()
    check("stop zera a memória de drag vivo", !monitor.hasLiveDragSession)
}

check("hide do overlay zera a memória de drag vivo sem recursar na policy",
      overlaySource.contains("monitor.clearLiveDragSession()"))

print("== 12. semântica de cancelamento (AppKit não tem pass-through) ==")

check("drop com setor é perform",
      TangerineDragPolicy.dropDecision(wheelVisible: true, fileCount: 1, hasSector: true, shiftHeld: true) == .perform)
check("drop no furo/vão/canto é cancel",
      TangerineDragPolicy.dropDecision(wheelVisible: true, fileCount: 1, hasSector: false, shiftHeld: true) == .cancel)
check("shift solto com a roda na tela é cancel",
      TangerineDragPolicy.dropDecision(wheelVisible: true, fileCount: 1, hasSector: true, shiftHeld: false) == .cancel)
check("roda nunca revelada é ignore (destino real segue dono)",
      TangerineDragPolicy.dropDecision(wheelVisible: false, fileCount: 1, hasSector: true, shiftHeld: true) == .ignore
        && TangerineDragPolicy.dropDecision(wheelVisible: true, fileCount: 0, hasSector: false, shiftHeld: true) == .ignore)
check("decisão de cancel nunca vira .copy",
      TangerineDragPolicy.dropOperation(armed: true, fileCount: 1, hasSector: false, shiftHeld: true) == [])
check("recusa dentro do painel tem caminho explícito de cancelamento",
      overlaySource.contains("TangerineDragPolicy.dropDecision(")
        && overlaySource.contains("private func cancelDrop()"))
check("overlay não reencaminha drag para outro destino",
      !overlaySource.contains("slideDraggedImage")
        && !overlaySource.contains("draggingDestinationWindow")
        && !overlaySource.contains("numberOfValidItemsForDrop")
        && !overlaySource.contains("NSDraggingSession"))
check("cancelamento encerra o gesto (drop performed + hide)",
      overlaySource.contains("private func cancelDrop()")
        && overlaySource.contains("monitor.noteDropPerformed()"))

print("== 13. energia do polling ==")

check("polling ocioso é 20 Hz", abs(TangerineGestureBackend.polling.pollInterval(armed: false) - 1.0 / 20) < 1e-9)
check("polling armado é 60 Hz", abs(TangerineGestureBackend.polling.pollInterval(armed: true) - 1.0 / 60) < 1e-9)
check("monitor ocioso também é 20 Hz", abs(TangerineGestureBackend.eventMonitor.pollInterval(armed: false) - 1.0 / 20) < 1e-9)
check("ocioso é totalmente coalescível (tolerância = intervalo)",
      TangerineGestureBackend.polling.pollTolerance(armed: false)
        == TangerineGestureBackend.polling.pollInterval(armed: false))
check("armado usa tolerância menor",
      TangerineGestureBackend.polling.pollTolerance(armed: true)
        < TangerineGestureBackend.polling.pollInterval(armed: true))
check("timer usa a tolerância da policy", overlaySource.contains("backend.pollTolerance(armed: armed)"))

print("== 14. wiring do AppDelegate (fonte) ==")

let appDelegateSource: String = {
    let url = sourceRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/AppDelegate.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}()

check("fonte do AppDelegate foi lida", !appDelegateSource.isEmpty)
check("AppDelegate liga o feedback da roda flutuante",
      appDelegateSource.contains("FloatingRadialView.installFeedback("))
check("o hook de setor vai para o cue de sectorChanged",
      appDelegateSource.contains("sectorChanged: { [weak self] in self?.playFeedback(.sectorChanged) }"))
check("o hook de seleção vai para o cue de selection",
      appDelegateSource.contains("selection: { [weak self] in self?.playFeedback(.selection) }"))
check("o teardown desliga os dois hooks",
      appDelegateSource.contains("FloatingRadialView.installFeedback(sectorChanged: nil, selection: nil)"))
check("install e teardown aparecem uma vez cada",
      appDelegateSource.components(separatedBy: "FloatingRadialView.installFeedback").count == 3)

print("\n\(checks - failures)/\(checks) checks")
if failures > 0 {
    print("radial-gesture: \(failures) falha(s)")
    exit(1)
}
print("radial-gesture: ok")
