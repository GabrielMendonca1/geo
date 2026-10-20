import AppKit

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    check(lhs == rhs, "\(message) (got \(lhs), want \(rhs))")
}

func close(_ lhs: CGFloat, _ rhs: CGFloat, _ tolerance: CGFloat, _ message: String) {
    check(abs(lhs - rhs) <= tolerance, "\(message) (got \(lhs), want \(rhs)±\(tolerance))")
}

// MARK: - Opções flat vindas do backend

let movWheel = FloatingRadialOptions.convert(category: .video, sourceExtension: "mov")
equal(movWheel.map { $0.format ?? "" }, ["mp4", "mkv", "gif", "mp3", "m4a"], "MOV converte horário a partir do topo")
check(movWheel.allSatisfy { $0.kind == "convert" }, "roda de conversão só tem convert")
check(movWheel.allSatisfy { !FloatingRadialOptions.packageFormats.contains($0.format ?? "") }, "sem formatos de pacote no vídeo")

let mp4Wheel = FloatingRadialOptions.convert(category: .video, sourceExtension: "MP4")
check(!mp4Wheel.contains { $0.format == "mp4" }, "origem não aparece na própria roda")

let pngWheel = FloatingRadialOptions.convert(category: .images, sourceExtension: "png")
check(!pngWheel.isEmpty, "imagens têm conversões")
check(!pngWheel.contains { $0.format == "png" }, "png fora da roda de png")
check(pngWheel.allSatisfy { !FloatingRadialOptions.packageFormats.contains($0.format ?? "") }, "sem pacote nas imagens")

let gifWheel = FloatingRadialOptions.convert(category: .images, sourceExtension: "gif")
check(gifWheel.contains { $0.format == "mp4" }, "gif ganha alvos animados (dependente da origem)")
check(!pngWheel.contains { $0.format == "mp4" }, "png não ganha alvos animados")

let limited = FilesCapability(kinds: ["convert"], formats: ["mp4", "zip"])
let limitedWheel = FloatingRadialOptions.convert(category: .video, sourceExtension: "mov", capability: limited)
equal(limitedWheel.map { $0.format ?? "" }, ["mp4"], "capability do backend manda e pacote continua fora")

let videoTools = FloatingRadialOptions.tools(category: .video)
equal(
    videoTools.map(\.kind),
    ["compress", "removeMetadata", "mute", "trim", "crop", "speed", "snapshot", "split"],
    "ferramentas de vídeo horário a partir do topo"
)
let cappedTools = FloatingRadialOptions.tools(
    category: .video,
    capability: FilesCapability(kinds: ["trim", "mute"], formats: [])
)
equal(cappedTools.map(\.kind), ["mute", "trim"], "ferramentas respeitam capability")

// MARK: - Ordem canônica: permutar a origem não muda a roda

func lcg(_ seed: UInt64) -> () -> UInt64 {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    return {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 16
    }
}

func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
    var out = items
    let next = lcg(seed)
    guard out.count > 1 else { return out }
    for index in stride(from: out.count - 1, to: 0, by: -1) {
        let pick = Int(next() % UInt64(index + 1))
        out.swapAt(index, pick)
    }
    return out
}

let movGroups = FilesCatalog.convertGroups(category: .video, sourceExtension: "mov")
let movCanonical = FloatingRadialOptions.normalizeConvert(movGroups.flatMap(\.options))
equal(movCanonical.map { $0.format ?? "" }, ["mp4", "mkv", "gif", "mp3", "m4a"], "normalizeConvert dá a ordem canônica do MOV")

var permutedStable = true
var permutationCount = 0
for seed in UInt64(1) ... 24 {
    let permutedGroups = shuffled(movGroups, seed: seed).map {
        FilesGroup(title: $0.title, options: shuffled($0.options, seed: seed &* 7 &+ 3))
    }
    let flat = permutedGroups.flatMap(\.options)
    permutationCount += 1
    if FloatingRadialOptions.normalizeConvert(flat).map(\.id) != movCanonical.map(\.id) { permutedStable = false }
    if FloatingRadialOptions.normalizeConvert(shuffled(flat, seed: seed &+ 101)).map(\.id) != movCanonical.map(\.id) {
        permutedStable = false
    }
}
check(permutedStable, "MOV: \(permutationCount) permutações de grupos/opções dão a mesma roda")
check(
    FloatingRadialOptions.normalizeConvert(movGroups.flatMap(\.options).reversed()).map(\.id) == movCanonical.map(\.id),
    "MOV invertido volta à ordem canônica"
)

let toolCanonical = FloatingRadialOptions.normalizeTools(FilesCatalog.toolGroups(category: .video).flatMap(\.options))
var toolsStable = true
for seed in UInt64(1) ... 24 {
    let permuted = shuffled(FilesCatalog.toolGroups(category: .video), seed: seed).map {
        FilesGroup(title: $0.title, options: shuffled($0.options, seed: seed &* 11 &+ 5))
    }
    if FloatingRadialOptions.normalizeTools(permuted.flatMap(\.options)).map(\.id) != toolCanonical.map(\.id) {
        toolsStable = false
    }
}
check(toolsStable, "ferramentas permutadas voltam à ordem horária fixa")
check(
    FloatingRadialOptions.normalize(shuffled(movGroups.flatMap(\.options), seed: 77), mode: .convert).map(\.id)
        == movCanonical.map(\.id),
    "normalize(mode: .convert) delega para a ordem canônica"
)

// MARK: - View

let view = FloatingRadialView(frame: NSRect(origin: .zero, size: FloatingRadialView.viewSize(diameter: 360)))
view.diameter = 360
view.fileName = "clipe-da-viagem.mov"
view.options = movWheel

// Tamanho / clamp
equal(FloatingRadialView.clampDiameter(100), 320, "clamp mínimo")
equal(FloatingRadialView.clampDiameter(1000), 380, "clamp máximo")
equal(FloatingRadialView.clampDiameter(340), 340, "clamp respeita faixa")
equal(FloatingRadialView.viewSize(diameter: 360), NSSize(width: 388, height: 388), "lado = diâmetro + padding")
equal(FloatingRadialView.viewSize(diameter: 4000), NSSize(width: 408, height: 408), "viewSize também clampa")
view.diameter = 5000
equal(view.diameter, 380, "diâmetro atribuído é clampado")
view.diameter = 360

// Não-key, sem foco, sem mouse
check(!view.acceptsFirstResponder, "não vira first responder")
check(!view.canBecomeKeyView, "não entra na cadeia de foco")
check(view.hitTest(view.centerCoordinates()) == nil, "hitTest nil: transparente ao mouse")

// Geometria: índice 0 no topo, horário
let center = view.centerCoordinates()
equal(center, NSPoint(x: view.bounds.midX, y: view.bounds.midY), "centerCoordinates no meio")
close(view.sectorMidAngle(0) ?? -1, 90, 0.001, "setor 0 no topo")
close(view.sectorMidAngle(1) ?? -1, 90 - 72, 0.001, "setor 1 é o próximo no horário")
close(view.sectorMidAngle(4) ?? -1, 90 + 72, 0.001, "último setor fecha o círculo")
if let span = view.sectorSpan(0) {
    close(span.end - span.start, 72, 0.001, "largura do setor = 360/n")
    close((span.start + span.end) / 2, 90, 0.001, "setor 0 é centrado no topo")
}
check(view.sectorSpan(5) == nil, "índice fora da faixa não tem setor")
if let top = view.sectorMidpoint(0) {
    check(top.y > center.y && abs(top.x - center.x) < 0.001, "ponto médio do setor 0 fica acima do centro")
}
if let right = view.sectorMidpoint(1) {
    check(right.x > center.x && right.y > center.y, "setor 1 fica à direita/acima (horário)")
}
close(view.holeRadius, 360 * 0.170, 0.001, "raio do furo")
close(view.sectorOuterRadius, 360 * 0.490, 0.001, "raio externo")
check(view.sectorInnerRadius > view.holeRadius, "furo é menor que o anel")

// Hit-testing
func at(angle: CGFloat, radius: CGFloat) -> NSPoint {
    NSPoint(x: center.x + cos(angle * .pi / 180) * radius, y: center.y + sin(angle * .pi / 180) * radius)
}
let ringRadius = (view.sectorInnerRadius + view.sectorOuterRadius) / 2
equal(view.hit(at: center), .center, "centro é o furo")
equal(view.hit(at: at(angle: 0, radius: view.holeRadius * 0.5)), .center, "dentro do furo")
equal(view.hit(at: at(angle: 90, radius: ringRadius)), .sector(0), "topo é o setor 0")
equal(view.hit(at: at(angle: 18, radius: ringRadius)), .sector(1), "horário chega no setor 1")
equal(view.hit(at: at(angle: 162, radius: ringRadius)), .sector(4), "anti-horário chega no último")
equal(view.hit(at: at(angle: 45, radius: view.sectorOuterRadius + 12)), .outside, "além do anel é fora")
equal(
    view.hit(at: at(angle: 45, radius: (view.holeRadius + view.sectorInnerRadius) / 2)),
    .outside,
    "vão entre furo e anel é fora"
)

// Seleção só em mudança real + ticks
var ticks = 0
var selectionEvents: [String?] = []
FloatingRadialView.playSectorChangedFeedback = { ticks += 1 }
var confirmations = 0
FloatingRadialView.playSelectionFeedback = { confirmations += 1 }
view.onSelectionChange = { selectionEvents.append($0?.format) }
var committed: [String] = []
view.onCommit = { committed.append($0.format ?? $0.kind) }

equal(view.trackHit(at: at(angle: 90, radius: ringRadius)), .sector(0), "track devolve o setor")
equal(view.trackHit(at: at(angle: 80, radius: ringRadius)), .sector(0), "mesmo setor continua o mesmo")
equal(view.trackHit(at: at(angle: 18, radius: ringRadius)), .sector(1), "arrasto muda de setor")
equal(ticks, 2, "tick só na mudança real de setor")
equal(selectionEvents, ["mp4", "mkv"], "onSelectionChange só na mudança real")

equal(view.trackHit(at: center), .center, "voltar ao centro")
equal(view.selectedIndex, nil, "centro zera a seleção")
equal(selectionEvents, ["mp4", "mkv", nil], "centro avisa nil")
equal(ticks, 2, "voltar ao centro não faz tick")
view.commit()
equal(committed, [], "commit sem seleção não faz nada")
equal(confirmations, 0, "sem som de confirmação sem seleção")

equal(view.trackHit(at: at(angle: 270, radius: view.sectorOuterRadius + 40)), .outside, "fora do anel")
equal(view.selectedIndex, nil, "fora zera a seleção")
equal(ticks, 2, "fora não faz tick")

view.trackHit(at: at(angle: 90, radius: ringRadius))
equal(view.selectedIndex, 0, "voltou ao setor 0")
equal(ticks, 3, "tick ao reentrar")
view.commit()
equal(committed, ["mp4"], "commit entrega a opção selecionada")
equal(confirmations, 1, "som de confirmação no commit")

// Trocar as opções invalida seleção fora da faixa
view.options = FloatingRadialOptions.tools(category: .video)
view.trackHit(at: at(angle: 90 - 45, radius: ringRadius))
equal(view.selectedIndex, 1, "8 ferramentas: 45° abaixo do topo é a segunda")
view.options = movWheel
equal(view.selectedIndex, 1, "seleção válida sobrevive à troca")
view.options = [movWheel[0]]
equal(view.selectedIndex, nil, "seleção fora da faixa é zerada")
view.options = movWheel
view.clearSelection()

// MARK: - Contrato FilesWheelSurface (worker do gesto)

check(NSClassFromString("FloatingRadialView") is FilesWheelSurface.Type, "lookup dinâmico acha a superfície")
let surface: FilesWheelSurface = FloatingRadialView(frame: NSRect(x: 0, y: 0, width: 348, height: 348))
close(surface.preferredSide, 348, 0.001, "preferredSide = diâmetro + padding")
surface.apply(
    groups: FilesCatalog.convertGroups(category: .video, sourceExtension: "mov"),
    mode: .convert,
    headline: "ignorado",
    footnote: "ignorado"
)
if let wheel = surface as? FloatingRadialView {
    equal(wheel.options.map { $0.format ?? "" }, ["mp4", "mkv", "gif", "mp3", "m4a"], "apply achata grupos e corta pacote")
}
let surfaceCenter = NSPoint(x: 174, y: 174)
let surfaceRing = 320 * (0.215 + 0.490) / 2
check(surface.track(at: NSPoint(x: surfaceCenter.x, y: surfaceCenter.y + surfaceRing)), "track no setor devolve true")
check(surface.selectedOption?.format == "mp4", "selectedOption segue o track")
check(!surface.track(at: surfaceCenter), "track no furo devolve false")
check(surface.selectedOption == nil, "furo zera selectedOption")
check(!surface.track(at: NSPoint(x: 4, y: 4)), "track fora do anel devolve false")
surface.track(at: NSPoint(x: surfaceCenter.x, y: surfaceCenter.y + surfaceRing))
surface.apply(
    groups: FilesCatalog.toolGroups(category: .video),
    mode: .tools,
    headline: "",
    footnote: ""
)
check(surface.selectedOption == nil, "troca de modo sem a opção anterior zera a seleção")
if let wheel = surface as? FloatingRadialView {
    equal(
        wheel.options.map(\.kind),
        ["compress", "removeMetadata", "mute", "trim", "crop", "speed", "snapshot", "split"],
        "apply em tools usa a ordem horária fixa"
    )
}
surface.track(at: NSPoint(x: surfaceCenter.x, y: surfaceCenter.y + surfaceRing))
check(surface.selectedOption?.kind == "compress", "topo das ferramentas é compress")
surface.apply(groups: FilesCatalog.toolGroups(category: .video), mode: .tools, headline: "", footnote: "")
check(surface.selectedOption?.kind == "compress", "apply preserva a seleção ainda válida")
surface.reset()
check(surface.selectedOption == nil, "reset limpa a seleção")

let permutedSurface = FloatingRadialView(frame: NSRect(x: 0, y: 0, width: 348, height: 348))
permutedSurface.apply(
    groups: shuffled(movGroups, seed: 9).map { FilesGroup(title: $0.title, options: shuffled($0.options, seed: 31)) },
    mode: .convert,
    headline: "",
    footnote: ""
)
equal(permutedSurface.options.map { $0.format ?? "" }, ["mp4", "mkv", "gif", "mp3", "m4a"], "apply normaliza grupos permutados")
let permutedTools = FloatingRadialView(frame: NSRect(x: 0, y: 0, width: 348, height: 348))
permutedTools.apply(
    groups: shuffled(FilesCatalog.toolGroups(category: .video), seed: 5).map {
        FilesGroup(title: $0.title, options: shuffled($0.options, seed: 13))
    },
    mode: .tools,
    headline: "",
    footnote: ""
)
equal(
    permutedTools.options.map(\.kind),
    ["compress", "removeMetadata", "mute", "trim", "crop", "speed", "snapshot", "split"],
    "apply em tools normaliza grupos permutados"
)

// MARK: - Metadados do arquivo arrastado (setFiles)

let metaView = FloatingRadialView(frame: NSRect(x: 0, y: 0, width: 348, height: 348))
metaView.setFiles([])
equal(metaView.fileName, "", "setFiles vazio limpa o nome")
check(metaView.fileIcon == nil, "setFiles vazio limpa o ícone")
let metaDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("floating-meta-\(getpid())")
try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
let metaFile = metaDir.appendingPathComponent("clipe-da-viagem.mov")
FileManager.default.createFile(atPath: metaFile.path, contents: Data([0x00]))
let metaSecond = metaDir.appendingPathComponent("outro.mp4")
FileManager.default.createFile(atPath: metaSecond.path, contents: Data([0x00]))
metaView.setFiles([metaFile])
equal(metaView.fileName, "clipe-da-viagem.mov", "setFiles alimenta o nome do arquivo")
equal(metaView.sourceExtension, "mov", "setFiles expõe a extensão de origem")
check(metaView.fileIcon != nil, "setFiles alimenta o ícone do arquivo")
check((metaView.fileIcon?.size.width ?? 0) > 0, "ícone tem tamanho")
equal(metaView.files.map(\.lastPathComponent), ["clipe-da-viagem.mov"], "setFiles guarda as URLs")
metaView.setFiles([metaFile, metaSecond])
equal(metaView.fileName, "2 arquivos", "múltiplos arquivos viram contagem")
equal(metaView.files.count, 2, "setFiles guarda as duas URLs")
check(metaView.selectedOption == nil, "setFiles não seleciona nada")
check(metaView.window == nil, "setFiles não cria janela nem ativa o app")
metaView.setFiles([])
check(metaView.fileIcon == nil && metaView.files.isEmpty, "setFiles([]) volta ao estado vazio")
try? FileManager.default.removeItem(at: metaDir)

var installedTicks = 0
var installedConfirms = 0
FloatingRadialView.installFeedback(sectorChanged: { installedTicks += 1 }, selection: { installedConfirms += 1 })
let hookView = FloatingRadialView(frame: NSRect(x: 0, y: 0, width: 348, height: 348))
hookView.options = movWheel
hookView.trackHit(at: NSPoint(x: 174, y: 174 + 320 * (0.215 + 0.490) / 2))
hookView.commit()
equal(installedTicks, 1, "installFeedback liga o tick de setor")
equal(installedConfirms, 1, "installFeedback liga o som de confirmação")
FloatingRadialView.installFeedback(sectorChanged: nil, selection: nil)
check(
    FloatingRadialView.playSectorChangedFeedback == nil && FloatingRadialView.playSelectionFeedback == nil,
    "installFeedback(nil, nil) desliga os hooks"
)

// MARK: - Screenshot offscreen real

FloatingRadialView.playSectorChangedFeedback = nil
FloatingRadialView.playSelectionFeedback = nil

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let window = NSWindow(
    contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: view.bounds.size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.contentView = view
view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
view.diameter = 360
view.trackHit(at: at(angle: 90, radius: ringRadius))
view.layoutSubtreeIfNeeded()
view.display()

guard let shot = view.snapshotImage() else {
    print("FAIL snapshot offscreen indisponível")
    exit(1)
}
check(shot.pixelsWide > 0 && shot.pixelsHigh > 0, "snapshot tem pixels")

let scaleX = CGFloat(shot.pixelsWide) / view.bounds.width
let scaleY = CGFloat(shot.pixelsHigh) / view.bounds.height

func pixel(_ point: NSPoint, in rep: NSBitmapImageRep = shot) -> NSColor? {
    let x = Int((point.x * scaleX).rounded())
    let y = Int(((view.bounds.height - point.y) * scaleY).rounded())
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
}

// Sem a vibrancy (que renderiza opaca fora da tela) sobra só o desenho da roda.
guard let plain = view.snapshotImage(includingBackdrop: false) else {
    print("FAIL snapshot sem vibrancy indisponível")
    exit(1)
}

func isOrange(_ color: NSColor?) -> Bool {
    guard let color, color.alphaComponent > 0.5 else { return false }
    return color.redComponent > 0.6 && color.greenComponent < 0.65 && color.blueComponent < 0.45
        && color.redComponent - color.blueComponent > 0.35
}

func isCream(_ color: NSColor?) -> Bool {
    guard let color, color.alphaComponent > 0.25 else { return false }
    return color.redComponent > 0.55
        && abs(color.redComponent - color.blueComponent) < 0.12
        && abs(color.redComponent - color.greenComponent) < 0.12
}

if let hotPoint = view.sectorMidpoint(0) {
    let sample = pixel(NSPoint(x: hotPoint.x, y: hotPoint.y + 14))
    check(isOrange(sample), "setor ativo desenha laranja (\(sample.map(String.init(describing:)) ?? "nil"))")
}
for index in 1 ..< movWheel.count {
    if let point = view.sectorMidpoint(index) {
        let probe = NSPoint(
            x: center.x + (point.x - center.x) * 1.25,
            y: center.y + (point.y - center.y) * 1.25
        )
        let sample = pixel(probe)
        check(isCream(sample), "setor \(index) desenha creme (\(sample.map(String.init(describing:)) ?? "nil"))")
        let bare = pixel(probe, in: plain)
        check(
            (bare?.alphaComponent ?? 1) < 0.9 && (bare?.alphaComponent ?? 0) > 0.2,
            "setor \(index) é translúcido, não opaco (\(bare?.alphaComponent ?? -1))"
        )
    }
}
check((pixel(NSPoint(x: 2, y: 2))?.alphaComponent ?? 1) < 0.05, "canto da view é transparente (sem moldura/card)")
if let gap = pixel(at(angle: 90 - 36, radius: ringRadius)) {
    check(gap.alphaComponent < 0.3, "setores são separados: o vão entre eles é vazado")
}
// A pílula é o único bloco branco dentro do furo. A largura dela depende das
// métricas do texto da opção escolhida, então amostrar um ponto fixo (offset em
// fração do raio do furo) cai fora da pílula ou em cima de um glifo. Aqui a
// pílula é localizada por varredura do furo e só depois amostrada por dentro.
func isWhitePixel(_ color: NSColor?) -> Bool {
    guard let color, color.alphaComponent > 0.9 else { return false }
    // 0.85 separa a pílula (branco 0.97) do creme dos setores (~0.78).
    return min(color.redComponent, min(color.greenComponent, color.blueComponent)) > 0.85
}

let holeMinX = Int(((center.x - view.holeRadius) * scaleX).rounded())
let holeMaxX = Int(((center.x + view.holeRadius) * scaleX).rounded())
let holeMinY = Int(((view.bounds.height - (center.y + view.holeRadius)) * scaleY).rounded())
let holeMaxY = Int(((view.bounds.height - (center.y - view.holeRadius)) * scaleY).rounded())
var pillMinX = Int.max, pillMaxX = Int.min, pillMinY = Int.max, pillMaxY = Int.min
var pillWhitePixels = 0
for y in max(0, holeMinY) ... min(shot.pixelsHigh - 1, holeMaxY) {
    for x in max(0, holeMinX) ... min(shot.pixelsWide - 1, holeMaxX) {
        // Só dentro do furo: o creme dos setores também é claro.
        let vx = CGFloat(x) / scaleX - center.x
        let vy = view.bounds.height - CGFloat(y) / scaleY - center.y
        guard vx * vx + vy * vy <= pow(view.holeRadius * 0.94, 2) else { continue }
        guard isWhitePixel(shot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)) else { continue }
        pillWhitePixels += 1
        pillMinX = min(pillMinX, x); pillMaxX = max(pillMaxX, x)
        pillMinY = min(pillMinY, y); pillMaxY = max(pillMaxY, y)
    }
}
check(pillWhitePixels > 200, "pílula branca no furo central (\(pillWhitePixels) px brancos)")
if pillWhitePixels > 200 {
    let pillWidth = pillMaxX - pillMinX
    let pillHeight = pillMaxY - pillMinY
    let area = (pillWidth + 1) * (pillHeight + 1)
    let coverage = Double(pillWhitePixels) / Double(area)
    // O bloco é uma pílula com texto escuro dentro: a maior parte da caixa é branca.
    check(coverage > 0.6, "pílula é um bloco branco, não respingos de texto (\(coverage))")
    check(pillWidth > pillHeight, "pílula é mais larga que alta (\(pillWidth)x\(pillHeight))")
    // Amostras determinísticas nas colunas de padding (à esquerda e à direita do
    // texto, já dentro da borda arredondada) — longe de glifo e de sombra.
    let midY = (pillMinY + pillMaxY) / 2
    let inset = max(2, Int((Double(pillWidth) * 0.06).rounded()))
    var samples: [(Int, Int)] = []
    for dy in [-1, 0, 1] {
        let y = midY + dy * max(1, pillHeight / 5)
        samples.append((pillMinX + inset, y))
        samples.append((pillMaxX - inset, y))
    }
    var darkest = 1.0
    var opaque = true
    for (x, y) in samples {
        let color = shot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        let white = color.map { min($0.redComponent, min($0.greenComponent, $0.blueComponent)) } ?? 0
        darkest = min(darkest, Double(white))
        opaque = opaque && (color?.alphaComponent ?? 0) > 0.9
    }
    check(opaque, "interior da pílula é opaco")
    check(darkest > 0.75, "pílula é branca (\(samples.count) amostras internas, pior = \(darkest))")
}

// Arquivo arrastado no furo: ícone desenhado + pílula com o nome quando nada está escolhido
view.clearSelection()
view.fileIcon = nil
view.display()
let withoutIcon = view.snapshotImage(includingBackdrop: false)
let icon = NSImage(size: NSSize(width: 64, height: 64))
icon.lockFocus()
NSColor.systemBlue.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
icon.unlockFocus()
view.fileIcon = icon
view.display()
if let withIcon = view.snapshotImage(includingBackdrop: false),
   let base = withoutIcon {
    let probe = NSPoint(x: center.x, y: center.y + view.holeRadius * 0.3)
    let before = pixel(probe, in: base)?.alphaComponent ?? 0
    let after = pixel(probe, in: withIcon)
    check(before < 0.5, "furo sem ícone fica vazado")
    check((after?.alphaComponent ?? 0) > 0.8 && (after?.blueComponent ?? 0) > 0.5, "ícone do arquivo arrastado aparece no furo")
}
view.fileIcon = nil
view.trackHit(at: at(angle: 90, radius: ringRadius))

// Um segundo snapshot com outro setor ativo precisa diferir de verdade
view.trackHit(at: at(angle: 18, radius: ringRadius))
view.display()
if let second = view.snapshotImage(), let firstData = shot.representation(using: .png, properties: [:]),
   let secondData = second.representation(using: .png, properties: [:]) {
    check(firstData != secondData, "mudar o setor ativo muda o render")
}

let outDir = ProcessInfo.processInfo.arguments.count > 1 ? ProcessInfo.processInfo.arguments[1] : NSTemporaryDirectory()
if let data = shot.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("floating-radial.png")
    try? data.write(to: url)
    print("note snapshot -> \(url.path)")
}

// MARK: - Um anel só (nada de roda dentro de roda)

view.clearSelection()
view.setFiles([URL(fileURLWithPath: "/tmp/clipe-da-viagem.mov")])
view.options = movWheel
view.display()
guard let ringShot = view.snapshotImage(includingBackdrop: false) else {
    print("FAIL snapshot para o teste de anel único indisponível")
    exit(1)
}

func painted(_ point: NSPoint, in rep: NSBitmapImageRep) -> Bool {
    (pixel(point, in: rep)?.alphaComponent ?? 0) > 0.15
}

var singleRing = true
var ringDetail = ""
for index in movWheel.indices {
    guard let mid = view.sectorMidAngle(index) else { continue }
    var runs: [(CGFloat, CGFloat)] = []
    var current: (CGFloat, CGFloat)?
    var radius = view.holeRadius + 3
    while radius <= view.sectorOuterRadius + 20 {
        if painted(at(angle: mid, radius: radius), in: ringShot) {
            if var open = current {
                open.1 = radius
                current = open
            } else {
                current = (radius, radius)
            }
        } else if let open = current {
            runs.append(open)
            current = nil
        }
        radius += 1
    }
    if let open = current { runs.append(open) }
    let solid = runs.filter { $0.1 - $0.0 >= 3 }
    if solid.count != 1 {
        singleRing = false
        ringDetail = "setor \(index) tem \(solid.count) faixas pintadas"
    } else if let band = solid.first {
        if band.0 < view.sectorInnerRadius - 6 || band.1 > view.sectorOuterRadius + 6 {
            singleRing = false
            ringDetail = "setor \(index) pinta fora do anel (\(band.0)…\(band.1))"
        }
    }
}
check(singleRing, "um anel só por raio: sem roda aninhada \(ringDetail)")
check(
    !painted(at(angle: 90, radius: (view.holeRadius + view.sectorInnerRadius) / 2), in: ringShot),
    "o vão entre furo e anel fica vazio (sem anel interno)"
)

// MARK: - Frame realista: uma roda só sobre um desktop sintético

print("note este frame é composição offscreen sobre desktop sintético; não é E2E, não houve drag do Finder")

let frameSize = NSSize(width: 658, height: 540)

func makeRep(_ size: NSSize) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

func drawDesktop() {
    let rect = NSRect(origin: .zero, size: frameSize)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.96, green: 0.62, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.36, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.48, blue: 0.82, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: 305)
    let names = ["geese.mov", "geese.mp4"]
    for (index, name) in names.enumerated() {
        let origin = NSPoint(x: 70 + CGFloat(index) * 158, y: 330)
        let card = NSRect(origin: origin, size: NSSize(width: 82, height: 96))
        NSColor(white: 0.12, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: card.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
        NSColor(srgbRed: 0.24, green: 0.36, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (name as NSString).draw(
            in: NSRect(x: origin.x - 30, y: origin.y - 24, width: 142, height: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
        )
    }
}

view.clearSelection()
view.trackHit(at: at(angle: 90 - 72, radius: ringRadius))
view.display()

guard let wheelRep = view.snapshotImage(includingBackdrop: false),
      let plainDesktop = makeRep(frameSize),
      let composed = makeRep(frameSize),
      let desktopContext = NSGraphicsContext(bitmapImageRep: plainDesktop),
      let composedContext = NSGraphicsContext(bitmapImageRep: composed) else {
    print("FAIL composição do frame realista indisponível")
    exit(1)
}

let wheelImage = NSImage(size: view.bounds.size)
wheelImage.addRepresentation(wheelRep)
let wheelOrigin = NSPoint(
    x: (frameSize.width - view.bounds.width) / 2 + 34,
    y: (frameSize.height - view.bounds.height) / 2 + 42
)
let wheelRect = NSRect(origin: wheelOrigin, size: view.bounds.size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = desktopContext
drawDesktop()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = composedContext
drawDesktop()
wheelImage.draw(in: wheelRect, from: .zero, operation: .sourceOver, fraction: 1)
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: wheelRect.midX + 96, y: wheelRect.midY + 96))
cursor.line(to: NSPoint(x: wheelRect.midX + 96, y: wheelRect.midY + 58))
cursor.line(to: NSPoint(x: wheelRect.midX + 110, y: wheelRect.midY + 70))
cursor.close()
NSColor.white.setFill()
cursor.fill()
NSColor.black.setStroke()
cursor.lineWidth = 1.5
cursor.stroke()
NSGraphicsContext.restoreGraphicsState()

func frameColor(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
}

var minX = Int(frameSize.width)
var maxX = -1
var minY = Int(frameSize.height)
var maxY = -1
var changed = 0
for y in 0 ..< Int(frameSize.height) {
    for x in 0 ..< Int(frameSize.width) {
        guard let base = frameColor(plainDesktop, x, y), let over = frameColor(composed, x, y) else { continue }
        let delta = abs(base.redComponent - over.redComponent)
            + abs(base.greenComponent - over.greenComponent)
            + abs(base.blueComponent - over.blueComponent)
        guard delta > 0.04 else { continue }
        changed += 1
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
}

check(changed > 5_000, "a roda realmente cobre o desktop sintético (\(changed) px)")
let spanX = CGFloat(maxX - minX + 1)
let spanY = CGFloat(maxY - minY + 1)
check(
    spanX <= view.bounds.width + 24 && spanY <= view.bounds.height + 24,
    "tudo que aparece cabe numa roda só (\(Int(spanX))x\(Int(spanY)) px para lado \(Int(view.bounds.width)))"
)

let probeRadius = view.sectorInnerRadius + (view.sectorOuterRadius - view.sectorInnerRadius) * 0.88
let probeLocal = at(angle: view.sectorMidAngle(2) ?? 0, radius: probeRadius)
let sectorProbe = NSPoint(x: wheelRect.minX + probeLocal.x, y: wheelRect.minY + probeLocal.y)
let probeX = Int(sectorProbe.x.rounded())
let probeY = Int((frameSize.height - sectorProbe.y).rounded())
if let overSector = frameColor(composed, probeX, probeY), let underSector = frameColor(plainDesktop, probeX, probeY) {
    check(
        overSector.brightnessComponent > underSector.brightnessComponent,
        "setor creme clareia o desktop por baixo (\(overSector.brightnessComponent) > \(underSector.brightnessComponent))"
    )
    let creamDelta = abs(overSector.redComponent - 0.965) + abs(overSector.blueComponent - 0.941)
    check(creamDelta > 0.03, "setor continua translúcido sobre o desktop (não é creme chapado)")
}

let realisticURL = URL(fileURLWithPath: outDir).appendingPathComponent("floating-radial-desktop.png")
if let data = composed.representation(using: .png, properties: [:]) {
    try? data.write(to: realisticURL)
    print("note frame realista -> \(realisticURL.path)")
}

let referenceDir = "/tmp/whisper-e2e-probe"
let references = ((try? FileManager.default.contentsOfDirectory(atPath: referenceDir)) ?? [])
    .filter { $0.hasPrefix("f_") && $0.hasSuffix(".png") }
    .sorted()
if let first = references.first,
   let refImage = NSImage(contentsOfFile: "\(referenceDir)/\(first)"),
   let refRep = refImage.representations.first {
    let refSize = NSSize(width: refRep.pixelsWide, height: refRep.pixelsHigh)
    equal(refSize, frameSize, "frame sintético usa o mesmo tamanho das referências \(first)")
    let ratio = view.diameter / refSize.height
    check(ratio > 0.4 && ratio < 0.85, "diâmetro da roda é comparável ao da referência (\(ratio))")
    print("note referências disponíveis: \(references.count) frames em \(referenceDir)")
} else {
    print("note referências \(referenceDir)/f_*.png ausentes: comparação de tamanho pulada")
}

print("\n\(checks - failures)/\(checks) checagens passaram")
exit(failures == 0 ? 0 : 1)
