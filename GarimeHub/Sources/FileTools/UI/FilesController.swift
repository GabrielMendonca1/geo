import AppKit

protocol FilesSelectionResolving: AnyObject {
    @discardableResult
    func resolve(_ completion: @escaping (FileSelectionResolution) -> Void) -> UUID
}

extension FileSelectionResolver: FilesSelectionResolving {}

enum FilesContextualRevalidation: Equatable {
    case strict
    case off
}

public final class FilesController {
    private let engine: FilesRunning
    private let jobs: FilesJobCenter
    private let compact: FilesCompactAction
    private let toast = FilesToast()
    private let submissionObserver: (([FilesJob]) -> Void)?
    private var running = false

    private let makeSelectionResolver: () -> FilesSelectionResolving
    private let makeContextualPresenter: () -> FilesContextualPresenting
    private let frontmostProvider: () -> FileSelectionSource?
    private let anchorProvider: () -> NSPoint
    private let frontmostPIDProvider: () -> pid_t?
    private let runningPIDProbe: (pid_t) -> Bool
    private let activateSource: (pid_t) -> Void
    private let presentNotice: (FilesContextualNotice, NSPoint, (() -> Void)?) -> Void
    private let grantPermission: (FilesContextualNotice.Remedy) -> Void
    private let automationPreflight: () -> Bool
    private let accessibilityPreflight: () -> Bool
    private let ownPID: pid_t
    private let revalidation: FilesContextualRevalidation
    private var selectionResolver: FilesSelectionResolving?
    private var contextualPresenter: FilesContextualPresenting?
    private var contextualEpoch = 0
    private var contextualSession: ContextualSession?
    private var activationObserver: NSObjectProtocol?

    private struct ContextualSession {
        let id: UUID
        let sourcePID: pid_t
        let urls: [URL]
        let mode: FilesMode
        let anchor: NSPoint
        let revalidate: Bool
    }

    public convenience init() {
        self.init(engine: FileToolsBridge())
    }

    init(
        engine: FilesRunning,
        presentCompactParameters: (([URL], FilesOption) -> Void)? = nil,
        onSubmitted: (([FilesJob]) -> Void)? = nil,
        selectionResolver: FilesSelectionResolving? = nil,
        contextualPresenter: FilesContextualPresenting? = nil,
        frontmostProvider: (() -> FileSelectionSource?)? = nil,
        anchorProvider: (() -> NSPoint)? = nil,
        frontmostPIDProvider: (() -> pid_t?)? = nil,
        runningPIDProbe: ((pid_t) -> Bool)? = nil,
        activateSource: ((pid_t) -> Void)? = nil,
        presentNotice: ((FilesContextualNotice, NSPoint, (() -> Void)?) -> Void)? = nil,
        grantPermission: ((FilesContextualNotice.Remedy) -> Void)? = nil,
        automationPreflight: (() -> Bool)? = nil,
        accessibilityPreflight: (() -> Bool)? = nil,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        revalidation: FilesContextualRevalidation = .strict
    ) {
        self.engine = engine
        let jobs = FilesJobCenter(engine: engine)
        self.jobs = jobs
        compact = FilesCompactAction(jobs: jobs, presentParameters: presentCompactParameters)
        submissionObserver = onSubmitted
        self.selectionResolver = selectionResolver
        makeSelectionResolver = {
            FileSelectionResolver(
                frontmost: WorkspaceFrontmostApplicationProvider(),
                finder: FinderFileSelectionProvider(),
                accessibility: AXFileSelectionProvider()
            )
        }
        self.contextualPresenter = contextualPresenter
        makeContextualPresenter = { FilesContextualPanel() }
        self.frontmostProvider = frontmostProvider ?? { WorkspaceFrontmostApplicationProvider().frontmostApplication() }
        self.anchorProvider = anchorProvider ?? { NSEvent.mouseLocation }
        self.frontmostPIDProvider = frontmostPIDProvider
            ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.runningPIDProbe = runningPIDProbe ?? { NSRunningApplication(processIdentifier: $0) != nil }
        self.activateSource = activateSource ?? { pid in
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        let noticePanelBox = NoticePanelBox()
        self.presentNotice = presentNotice ?? { notice, anchor, onGrant in
            noticePanelBox.panel.show(notice, at: anchor, onGrant: onGrant)
        }
        self.grantPermission = grantPermission ?? { remedy in
            switch remedy {
            case .none:
                break
            case .automation:
                FinderFileSelectionProvider().requestPermission()
            case .accessibility:
                AXFileSelectionProvider().requestPermission()
            }
        }
        self.automationPreflight = automationPreflight ?? { FinderFileSelectionProvider().preflightPermission() }
        self.accessibilityPreflight = accessibilityPreflight ?? { AXFileSelectionProvider().preflightPermission() }
        self.ownPID = ownPID
        self.revalidation = revalidation
        wire()
    }

    private final class NoticePanelBox {
        lazy var panel = FilesContextualNoticePanel()
    }

    private func wire() {
        compact.onSubmitted = { [weak self] created in
            self?.submissionObserver?(created)
            self?.showToast(for: created)
        }
        jobs.addObserver("toast") { [weak self] in self?.toast.refresh() }
        if let contextualPresenter { bind(contextualPresenter) }
    }

    private func bind(_ target: FilesContextualPresenting) {
        target.onCommit = { [weak self] sessionID, option in
            self?.handleContextualCommit(sessionID: sessionID, option: option)
        }
        target.onDismiss = { [weak self] sessionID, reason in
            self?.handleContextualDismiss(sessionID: sessionID, reason: reason)
        }
    }

    @discardableResult
    func performSelectionAction(urls: [URL], option: FilesOption) -> Bool {
        guard !urls.isEmpty else { return false }
        compact.perform(inputs: urls, option: option)
        return true
    }

    private var presenter: FilesContextualPresenting {
        if let contextualPresenter { return contextualPresenter }
        let created = makeContextualPresenter()
        bind(created)
        contextualPresenter = created
        return created
    }

    private var resolver: FilesSelectionResolving {
        if let selectionResolver { return selectionResolver }
        let created = makeSelectionResolver()
        selectionResolver = created
        return created
    }

    public func invokeSelection(mode: FilesWheelMode = .convert) {
        invokeSelection(wheelMode: mode.mode)
    }

    func invokeSelection(wheelMode mode: FilesMode) {
        let capturedSource = frontmostProvider()
        let anchor = anchorProvider()
        invalidateContextual(reason: .reinvoked)
        guard let capturedSource else {
            show(FilesContextualNoticeFactory.notice(for: .noFrontmostApplication, source: nil), at: anchor)
            return
        }
        guard capturedSource.pid != ownPID else {
            show(FilesContextualNoticeFactory.ownApplicationNotice, at: anchor)
            return
        }
        let epoch = contextualEpoch
        resolver.resolve { [weak self] resolution in
            guard let self else { return }
            self.onMain {
                self.handleResolution(
                    resolution,
                    epoch: epoch,
                    expected: capturedSource,
                    mode: mode,
                    anchor: anchor
                )
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func handleResolution(
        _ resolution: FileSelectionResolution,
        epoch: Int,
        expected: FileSelectionSource,
        mode: FilesMode,
        anchor: NSPoint
    ) {
        guard epoch == contextualEpoch else { return }
        let source = resolution.source
        guard source?.pid == expected.pid else {
            show(FilesContextualNoticeFactory.notice(for: .sourceChanged, source: source), at: anchor)
            return
        }
        if let failure = resolution.failure {
            show(FilesContextualNoticeFactory.notice(for: failure, source: source), at: anchor)
            return
        }
        let urls = resolution.selectedURLs
        guard !urls.isEmpty else {
            let notice = resolution.hasDocumentCandidate
                ? FilesContextualNoticeFactory.documentOnlyNotice(source: source)
                : FilesContextualNoticeFactory.notice(
                    for: resolution.selectionAvailability == .unsupported ? .unsupported : .noSelection,
                    source: source
                )
            show(notice, at: anchor)
            return
        }
        presentWheel(urls: urls, mode: mode, sourcePID: expected.pid, anchor: anchor, revalidate: true)
    }

    public func invokeFiles(_ rawURLs: [URL], mode: FilesWheelMode) {
        invokeFiles(rawURLs, wheelMode: mode.mode)
    }

    func invokeFiles(_ rawURLs: [URL], wheelMode mode: FilesMode) {
        let anchor = anchorProvider()
        invalidateContextual(reason: .reinvoked)
        let urls: [URL]
        do {
            urls = try FileSelectionURLPolicy().validate(rawURLs)
        } catch let failure as FileSelectionFailure {
            show(FilesContextualNoticeFactory.notice(for: failure, source: nil), at: anchor)
            return
        } catch {
            show(FilesContextualNoticeFactory.notice(for: .invalidURL, source: nil), at: anchor)
            return
        }
        guard !urls.isEmpty else {
            show(FilesContextualNoticeFactory.notice(for: .noSelection, source: nil), at: anchor)
            return
        }
        presentWheel(urls: urls, mode: mode, sourcePID: frontmostPIDProvider() ?? ownPID, anchor: anchor, revalidate: false)
    }

    private func presentWheel(urls: [URL], mode: FilesMode, sourcePID: pid_t, anchor: NSPoint, revalidate: Bool) {
        let groups = compact.groups(for: urls, mode: mode)
        guard !groups.isEmpty else {
            show(FilesContextualNoticeFactory.noActionsNotice(urls: urls), at: anchor)
            return
        }
        let invocation = FilesContextualInvocation(
            urls: urls,
            mode: mode,
            sourcePID: sourcePID,
            anchor: anchor,
            groups: groups,
            headline: Self.headline(urls)
        )
        contextualSession = ContextualSession(
            id: invocation.id,
            sourcePID: sourcePID,
            urls: urls,
            mode: mode,
            anchor: anchor,
            revalidate: revalidate
        )
        guard presenter.present(invocation) else {
            contextualSession = nil
            show(FilesContextualNoticeFactory.noActionsNotice(urls: urls), at: anchor)
            return
        }
    }

    static func headline(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) arquivos"
    }

    func handleContextualDismiss(sessionID: UUID, reason: FilesContextualDismissReason) {
        guard let session = contextualSession, session.id == sessionID else { return }
        contextualSession = nil
        contextualEpoch += 1
        guard reason != .commit else { return }
        restoreFocus(to: session.sourcePID)
    }

    func handleContextualCommit(sessionID: UUID, option: FilesOption) {
        guard let session = contextualSession, session.id == sessionID else { return }
        contextualSession = nil
        contextualEpoch += 1
        let epoch = contextualEpoch
        let urls = session.urls
        restoreFocus(to: session.sourcePID)
        guard jobs.blocker(option: option, inputs: urls) == nil else {
            show(FilesContextualNoticeFactory.staleSelectionNotice, at: session.anchor)
            return
        }
        guard revalidation == .strict, session.revalidate else {
            performSelectionAction(urls: urls, option: option)
            return
        }
        resolver.resolve { [weak self] resolution in
            guard let self else { return }
            self.onMain {
                guard epoch == self.contextualEpoch else { return }
                if let failure = resolution.failure {
                    self.show(
                        FilesContextualNoticeFactory.revalidationNotice(
                            for: failure,
                            source: resolution.source
                        ),
                        at: session.anchor
                    )
                    return
                }
                guard resolution.source?.pid == session.sourcePID,
                      FilesContextualFileKeys.matches(resolution.selectedURLs, urls)
                else {
                    self.show(FilesContextualNoticeFactory.staleSelectionNotice, at: session.anchor)
                    return
                }
                self.performSelectionAction(urls: urls, option: option)
            }
        }
    }

    func handleApplicationActivation(pid: pid_t) {
        guard let session = contextualSession else { return }
        guard FilesContextualFocus.shouldInvalidate(
            activatedPID: pid,
            sourcePID: session.sourcePID,
            ownPID: ownPID
        ) else { return }
        invalidateContextual(reason: .sourceChanged)
    }

    func invalidateContextual(reason: FilesContextualDismissReason) {
        contextualSession = nil
        contextualEpoch += 1
        contextualPresenter?.dismiss(reason: reason)
    }

    private func restoreFocus(to sourcePID: pid_t) {
        guard FilesContextualFocus.shouldRestore(
            sourcePID: sourcePID,
            frontmostPID: frontmostPIDProvider(),
            ownPID: ownPID,
            sourceRunning: runningPIDProbe(sourcePID)
        ) else { return }
        activateSource(sourcePID)
    }

    private func show(_ notice: FilesContextualNotice, at anchor: NSPoint) {
        let remedy = notice.remedy
        let onGrant: (() -> Void)? = remedy == .none
            ? nil
            : { [weak self] in self?.grantPermission(remedy) }
        presentNotice(notice, anchor, onGrant)
    }

    public func showSelectionSettings() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Roda por seleção"
        alert.informativeText = selectionSettingsSummary()
        alert.addButton(withTitle: "Permitir Automação do Finder")
        alert.addButton(withTitle: "Pedir Acessibilidade")
        alert.addButton(withTitle: "Fechar")
        NSApp.activate(ignoringOtherApps: true)
        handleSelectionSettingsResponse(alert.runModal())
    }

    func selectionSettingsSummary() -> String {
        let automation = automationPreflight() ? "concedida" : "pendente"
        let accessibility = accessibilityPreflight() ? "concedida" : "pendente"
        let keyboard = contextualPresenter?.keyboardDiagnosticSummary.map { "\nTeclado da roda: \($0)" } ?? ""
        return "Selecione arquivos no Finder ou na Mesa e chame a roda pelo atalho; a ação escolhida roda no mesmo motor de Arquivos.\n\nAutomação (Finder): \(automation)\nAcessibilidade (outros apps): \(accessibility)\(keyboard)\n\nAs permissões só são pedidas ao clicar nos botões abaixo."
    }

    func handleSelectionSettingsResponse(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            grantPermission(.automation(FilesContextualNoticeFactory.finderBundleIdentifier))
        case .alertSecondButtonReturn:
            grantPermission(.accessibility)
        default:
            break
        }
    }

    var contextualSessionID: UUID? { contextualSession?.id }

    var contextualSelection: [URL] { contextualSession?.urls ?? [] }

    private func showToast(for created: [FilesJob]) {
        guard !created.isEmpty else { return }
        toast.show(
            jobs: created,
            onCancel: { [weak self] batch in batch.forEach { self?.jobs.cancel($0) } }
        )
    }

    public func start() {
        guard !running else { return }
        running = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleApplicationActivation(pid: app.processIdentifier)
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        invalidateContextual(reason: .stopped)
        toast.hide()
        compact.close()
        jobs.cancelAll()
    }

    public var isRunning: Bool { running }

    public var activeJobs: Int { jobs.jobs.filter { $0.state == .running }.count }
}
