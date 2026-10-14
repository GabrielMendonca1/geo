import Foundation

var checks = 0
var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("ok   · \(name)")
    } else {
        failures += 1
        print("FAIL · \(name) \(detail())")
    }
}

final class FrontmostStub: FrontmostApplicationProviding {
    private let lock = NSLock()
    private var value: FileSelectionSource?

    init(_ value: FileSelectionSource?) { self.value = value }

    func set(_ newValue: FileSelectionSource?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func frontmostApplication() -> FileSelectionSource? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ProviderStub: FileSelectionProviding {
    var body: (FileSelectionSource) throws -> RawFileSelection

    init(_ body: @escaping (FileSelectionSource) throws -> RawFileSelection) {
        self.body = body
    }

    func selection(for source: FileSelectionSource) throws -> RawFileSelection {
        try body(source)
    }
}

final class PermissionStub: FileSelectionPermissionProviding {
    private let granted: Bool
    private(set) var requests = 0

    init(_ granted: Bool) { self.granted = granted }

    func preflightPermission() -> Bool { granted }

    @discardableResult func requestPermission() -> Bool {
        requests += 1
        return granted
    }
}

func awaitResolution(_ resolver: FileSelectionResolver) -> FileSelectionResolution {
    let semaphore = DispatchSemaphore(value: 0)
    var value: FileSelectionResolution?
    resolver.resolve {
        value = $0
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 3) == .timedOut {
        fatalError("resolver test timed out")
    }
    return value!
}

let temporaryPath = NSTemporaryDirectory().hasPrefix("/var/")
    ? "/private" + NSTemporaryDirectory()
    : NSTemporaryDirectory()
let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
    .appendingPathComponent("garime-selection-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("chosen.txt")
let document = root.appendingPathComponent("document.txt")
FileManager.default.createFile(atPath: file.path, contents: Data())
FileManager.default.createFile(atPath: document.path, contents: Data())

let finderSource = FileSelectionSource(pid: 101, bundleIdentifier: "com.apple.finder")
let otherSource = FileSelectionSource(pid: 202, bundleIdentifier: "example.editor")
let frontmost = FrontmostStub(finderSource)
let unused = ProviderStub { _ in throw FileSelectionFailure.unsupported }
var finderCalls = 0
let finder = ProviderStub { _ in
    finderCalls += 1
    return RawFileSelection(selectedURLs: [file], documentURL: nil)
}
let callback = DispatchQueue(label: "selection-tests.callback")
let resolver = FileSelectionResolver(frontmost: frontmost, finder: finder, accessibility: unused, callbackQueue: callback)
let first = awaitResolution(resolver)
check("Finder usa apenas o provedor Finder", first.selectedURLs == [file] && finderCalls == 1, String(describing: first.failure))
check("resultado válido não tem falha", first.failure == nil, String(describing: first.failure))

let noSelectionProvider = ProviderStub { _ in RawFileSelection(selectedURLs: [], documentURL: nil) }
let noSelectionResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: noSelectionProvider,
    accessibility: unused,
    callbackQueue: callback
)
let empty = awaitResolution(noSelectionResolver)
check("ausência de seleção é distinta", empty.failure == .noSelection)
check("falha limpa todos os dados, sem seleção velha", empty.candidates.isEmpty && empty.selectedURLs.isEmpty)
check("cada invocação recebe UUID novo", empty.requestID != first.requestID)

frontmost.set(otherSource)
let documentProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [], documentURL: document, selectionAvailability: .unsupported)
}
let documentResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: documentProvider,
    callbackQueue: callback
)
let documentOnly = awaitResolution(documentResolver)
check("documento ativo não é seleção", documentOnly.selectedURLs.isEmpty && documentOnly.hasDocumentCandidate, String(describing: documentOnly.failure))
check("seleção AX não suportada permanece distinguível", documentOnly.selectionAvailability == .unsupported)
check("documento exige chamada explícita de confirmação", documentOnly.confirmDocumentCandidate() == document)
check("candidato documento conserva origem própria", documentOnly.candidates == [.init(kind: .document, url: document)])

let unsupportedProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [], documentURL: nil, selectionAvailability: .unsupported)
}
let unsupportedResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: unsupportedProvider,
    callbackQueue: callback
)
check("AX sem atributo e sem documento é unsupported", awaitResolution(unsupportedResolver).failure == .unsupported)

let remoteProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [URL(string: "file://remote.example/tmp/a.txt")!], documentURL: nil)
}
let remoteResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: remoteProvider,
    callbackQueue: callback
)
let remote = awaitResolution(remoteResolver)
check("file URL com host remoto é recusada", remote.failure == .invalidURL && remote.candidates.isEmpty)

let httpsProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [URL(string: "https://example.test/a.txt")!], documentURL: nil)
}
let httpsResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: httpsProvider,
    callbackQueue: callback
)
check("esquema não-file é recusado", awaitResolution(httpsResolver).failure == .invalidURL)

let changingProvider = ProviderStub { _ in
    frontmost.set(FileSelectionSource(pid: 303, bundleIdentifier: "other.app"))
    return RawFileSelection(selectedURLs: [file], documentURL: nil)
}
frontmost.set(otherSource)
let changingResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: changingProvider,
    callbackQueue: callback
)
let changed = awaitResolution(changingResolver)
check("troca da fonte durante resolução falha fechada", changed.failure == .sourceChanged && changed.candidates.isEmpty)

frontmost.set(otherSource)
for expected in [FileSelectionFailure.timeout, .providerError] {
    let failing = ProviderStub { _ in throw expected }
    let failureResolver = FileSelectionResolver(
        frontmost: frontmost,
        finder: unused,
        accessibility: failing,
        callbackQueue: callback
    )
    let result = awaitResolution(failureResolver)
    check("falha \(expected) é preservada e vazia", result.failure == expected && result.candidates.isEmpty)
}

let link = root.appendingPathComponent("link.txt")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
let linkProvider = ProviderStub { _ in RawFileSelection(selectedURLs: [link], documentURL: nil) }
let linkResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: linkProvider,
    callbackQueue: callback
)
check("symlink é recusado sem seguir o destino", awaitResolution(linkResolver).failure == .symbolicLink)

let delayed = ProviderStub { _ in
    Thread.sleep(forTimeInterval: 0.2)
    return RawFileSelection(selectedURLs: [file], documentURL: nil)
}
let boundedResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: delayed,
    maximumCallers: 1,
    callbackQueue: callback
)
let firstSignal = DispatchSemaphore(value: 0)
var delayedResult: FileSelectionResolution?
boundedResolver.resolve { delayedResult = $0; firstSignal.signal() }
let busy = awaitResolution(boundedResolver)
check("singleflight limita chamadores concorrentes", busy.failure == .busy && busy.candidates.isEmpty)
_ = firstSignal.wait(timeout: .now() + 2)
check("requisição admitida conclui normalmente", delayedResult?.selectedURLs == [file])

frontmost.set(otherSource)
let badDocumentProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [file], documentURL: URL(string: "https://example.test/a.txt")!)
}
let badDocumentResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: badDocumentProvider,
    callbackQueue: callback
)
let badDocument = awaitResolution(badDocumentResolver)
check("documento inválido não destrói a seleção válida",
      badDocument.failure == nil && badDocument.selectedURLs == [file] && !badDocument.hasDocumentCandidate,
      String(describing: badDocument.failure))

let echoDocumentProvider = ProviderStub { _ in
    RawFileSelection(selectedURLs: [file], documentURL: file)
}
let echoDocumentResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: echoDocumentProvider,
    callbackQueue: callback
)
let echoDocument = awaitResolution(echoDocumentResolver)
check("documento igual à seleção não vira candidato duplicado",
      echoDocument.candidates == [.init(kind: .selection, url: file)],
      String(describing: echoDocument.candidates))

let stuckGate = DispatchSemaphore(value: 0)
let stuckProvider = ProviderStub { _ in
    _ = stuckGate.wait(timeout: .now() + 5)
    return RawFileSelection(selectedURLs: [file], documentURL: nil)
}
let stuckResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: stuckProvider,
    timeout: 0.2,
    callbackQueue: callback
)
let stuckLock = NSLock()
var stuckResults: [FileSelectionResolution] = []
let stuckSignal = DispatchSemaphore(value: 0)
stuckResolver.resolve { value in
    stuckLock.lock()
    stuckResults.append(value)
    stuckLock.unlock()
    stuckSignal.signal()
}
let stuckArrived = stuckSignal.wait(timeout: .now() + 2) == .success
stuckLock.lock()
let stuckFirst = stuckResults.first
stuckLock.unlock()
check("provider travado responde dentro do prazo", stuckArrived && stuckFirst?.failure == .timeout,
      String(describing: stuckFirst?.failure))
check("resposta de timeout não carrega dados", stuckFirst?.candidates.isEmpty ?? false)
stuckGate.signal()
Thread.sleep(forTimeInterval: 0.4)
stuckLock.lock()
let stuckCount = stuckResults.count
stuckLock.unlock()
check("completion é entregue exatamente uma vez", stuckCount == 1, "entregas=\(stuckCount)")

let mainResolver = FileSelectionResolver(frontmost: frontmost, finder: unused, accessibility: ProviderStub { _ in
    RawFileSelection(selectedURLs: [file], documentURL: nil)
})
var mainThreadCallback: Bool?
mainResolver.resolve { _ in mainThreadCallback = Thread.isMainThread }
let mainLimit = Date().addingTimeInterval(2)
while mainThreadCallback == nil && Date() < mainLimit {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
check("callback padrão chega na main queue", mainThreadCallback == true, String(describing: mainThreadCallback))

let spentDeadline = FileSelectionDeadline(seconds: 0)
check("deadline zerado já expirou", spentDeadline.hasExpired && spentDeadline.remainingSeconds == 0)
let liveDeadline = FileSelectionDeadline(seconds: 0.3)
check("deadline vivo tem saldo limitado", !liveDeadline.hasExpired && liveDeadline.remainingSeconds <= 0.3)
Thread.sleep(forTimeInterval: 0.35)
check("deadline expira com o tempo real", liveDeadline.hasExpired)

let permissionStub = PermissionStub(false)
check("estado de permissão default deriva do preflight passivo", permissionStub.permissionState() == .denied)

let realDirectory = root.appendingPathComponent("pasta", isDirectory: true)
try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
let nested = realDirectory.appendingPathComponent("dentro.txt")
FileManager.default.createFile(atPath: nested.path, contents: Data())
let directoryLink = root.appendingPathComponent("atalho", isDirectory: true)
try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)

func resolveURLs(_ urls: [URL]) -> FileSelectionResolution {
    frontmost.set(otherSource)
    let provider = ProviderStub { _ in RawFileSelection(selectedURLs: urls, documentURL: nil) }
    return awaitResolution(FileSelectionResolver(
        frontmost: frontmost,
        finder: unused,
        accessibility: provider,
        callbackQueue: callback
    ))
}

let directoryResult = resolveURLs([realDirectory])
check("diretório selecionado é aceito como candidato",
      directoryResult.failure == nil && directoryResult.selectedURLs.map(\.path) == [realDirectory.path],
      String(describing: directoryResult.failure))
check("caminho sob ancestral symlink é recusado",
      resolveURLs([directoryLink.appendingPathComponent("dentro.txt")]).failure == .symbolicLink)
check("caminho inexistente é recusado sem ler conteúdo",
      resolveURLs([root.appendingPathComponent("nao-existe.txt")]).failure == .invalidURL)
check("raiz do volume não é candidato válido",
      resolveURLs([URL(fileURLWithPath: "/")]).failure == .invalidURL)
let duplicated = resolveURLs([file, file])
check("duplicatas colapsam em um candidato", duplicated.selectedURLs == [file])

let reuseProvider = ProviderStub { _ in RawFileSelection(selectedURLs: [file], documentURL: nil) }
let reuseResolver = FileSelectionResolver(
    frontmost: frontmost,
    finder: unused,
    accessibility: reuseProvider,
    timeout: 0.15,
    callbackQueue: callback
)
let slowGate = DispatchSemaphore(value: 0)
reuseProvider.body = { _ in
    _ = slowGate.wait(timeout: .now() + 3)
    return RawFileSelection(selectedURLs: [file], documentURL: nil)
}
let reuseFirst = awaitResolution(reuseResolver)
check("primeira chamada estoura o prazo", reuseFirst.failure == .timeout)
slowGate.signal()
Thread.sleep(forTimeInterval: 0.3)
reuseProvider.body = { _ in RawFileSelection(selectedURLs: [file], documentURL: nil) }
let reuseSecond = awaitResolution(reuseResolver)
check("vaga volta a ficar livre depois do trabalho terminar",
      reuseSecond.selectedURLs == [file] && reuseSecond.failure == nil,
      String(describing: reuseSecond.failure))

func appleEventList(_ values: [String]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for value in values {
        list.insert(NSAppleEventDescriptor(string: value), at: 0)
    }
    return list
}

let parsed = try? FinderFileSelectionProvider.urls(
    from: appleEventList(["file:///tmp/a%20b.txt", "file:///tmp/c.txt"]),
    maximumItems: 8
)
check("lista Apple Event vira URLs decodificadas",
      parsed?.map(\.path) == ["/tmp/a b.txt", "/tmp/c.txt"],
      String(describing: parsed))

func parseFailure(_ descriptor: NSAppleEventDescriptor, _ maximum: Int = 8) -> FileSelectionFailure? {
    do {
        _ = try FinderFileSelectionProvider.urls(from: descriptor, maximumItems: maximum)
        return nil
    } catch let failure as FileSelectionFailure {
        return failure
    } catch {
        return nil
    }
}

check("resultado Apple Event que não é lista falha fechado",
      parseFailure(NSAppleEventDescriptor(string: "file:///tmp/a.txt")) == .providerError)
check("lista vazia é seleção vazia, não erro",
      (try? FinderFileSelectionProvider.urls(from: appleEventList([]), maximumItems: 8))?.isEmpty == true)
check("lista acima do teto é recusada antes de qualquer uso",
      parseFailure(appleEventList(["file:///tmp/a", "file:///tmp/b", "file:///tmp/c"]), 2) == .tooManyItems)
check("item da lista que não é file URL é recusado",
      parseFailure(appleEventList(["nao e uma url valida"])) == .invalidURL)
check("item da lista com esquema remoto é recusado",
      parseFailure(appleEventList(["https://example.test/a.txt"])) == .invalidURL)

func scriptError(_ number: Int) -> FileSelectionFailure {
    FinderFileSelectionProvider.failure(forScriptError: [NSAppleScript.errorNumber: number] as NSDictionary)
}

check("erro -1743 do Apple Event é permissão negada", scriptError(-1743) == .permissionDenied)
check("erro -1744 (consentimento pendente) não vira sucesso", scriptError(-1744) == .permissionDenied)
check("erro -1712 do Apple Event é timeout", scriptError(-1712) == .timeout)
check("erro 8001 do script é excesso de itens", scriptError(8001) == .tooManyItems)
check("erro desconhecido do script é providerError", scriptError(-1728) == .providerError)

let sourceDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/FileTools/Selection"
let sourceFiles = (try? FileManager.default.contentsOfDirectory(atPath: sourceDirectory)) ?? []
let sourceText = sourceFiles.filter { $0.hasSuffix(".swift") }.compactMap {
    try? String(contentsOfFile: (sourceDirectory as NSString).appendingPathComponent($0), encoding: .utf8)
}.joined(separator: "\n")
check("resolver não toca clipboard nem simula Cmd-C",
      !sourceText.localizedCaseInsensitiveContains("pasteboard")
        && !sourceText.contains("keyCode: 8")
        && !sourceText.contains("⌘C"))
check("Sources novos não têm comentários de linha inteira",
      !sourceText.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
check("Finder usa script fixo sem interpolação", !sourceText.contains("tell application \"\\(") && sourceText.contains("with timeout of 2 seconds"))
check("Finder exige lista Apple Event tipada", sourceText.contains("typeAEList"))
check("AX limita o trabalho total por prazo", sourceText.contains("FileSelectionDeadline"))
check("leitura do app frontmost respeita a main thread do AppKit",
      sourceText.contains("Thread.isMainThread") && sourceText.contains("NSWorkspace.shared.frontmostApplication"))
let resolverText = (try? String(
    contentsOfFile: (sourceDirectory as NSString).appendingPathComponent("FileSelectionResolver.swift"),
    encoding: .utf8
)) ?? ""
check("resolver nunca pede permissão nem promove prompt",
      !resolverText.isEmpty
        && !resolverText.contains("requestPermission")
        && !resolverText.contains("AXIsProcessTrustedWithOptions"))
let requestPermissionLines = sourceText.split(separator: "\n").filter { $0.contains("requestPermission") }
check("requestPermission só existe como declaração, nunca como chamada interna",
      !requestPermissionLines.isEmpty && requestPermissionLines.allSatisfy { $0.contains("func requestPermission") },
      requestPermissionLines.joined(separator: " | "))
check("AX lê apenas atributos de URL declarados",
      !sourceText.contains("kAXValueAttribute")
        && !sourceText.contains("kAXChildrenAttribute")
        && !sourceText.contains("kAXTitleAttribute")
        && !sourceText.contains("kAXSelectedTextAttribute"))

print("\n\(checks - failures)/\(checks) checks passaram")
exit(failures == 0 ? 0 : 1)
