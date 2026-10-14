import AppKit

protocol TangerineSelectionResolving: AnyObject {
    @discardableResult
    func resolve(_ completion: @escaping (FileSelectionResolution) -> Void) -> UUID
}

extension FileSelectionResolver: TangerineSelectionResolving {}

enum TangerineContextualRevalidation: Equatable {
    case strict
    case off
}

public final class TangerineController {
    private let engine: TangerineRunning
    private let jobs: TangerineJobCenter
    private let dashboard: LazyDashboard
    private let compact: TangerineCompactAction
    private let toast = TangerineToast()
    private let presentDashboard: () -> Void
    private let submissionObserver: (([TangerineJob]) -> Void)?
    private var running = false

    private let makeSelectionResolver: () -> TangerineSelectionResolving
    private let makeContextualPresenter: () -> TangerineContextualPresenting
    private let frontmostProvider: () -> FileSelectionSource?
    private let anchorProvider: () -> NSPoint
    private let frontmostPIDProvider: () -> pid_t?
    private let runningPIDProbe: (pid_t) -> Bool
    private let activateSource: (pid_t) -> Void
    private let presentNotice: (TangerineContextualNotice, NSPoint, (() -> Void)?) -> Void
    private let grantPermission: (TangerineContextualNotice.Remedy) -> Void
    private let automationPreflight: () -> Bool
    private let accessibilityPreflight: () -> Bool
    private let ownPID: pid_t
    private let revalidation: TangerineContextualRevalidation
    private var selectionResolver: TangerineSelectionResolving?
    private var contextualPresenter: TangerineContextualPresenting?
    private var contextualEpoch = 0
    private var contextualSession: ContextualSession?
    private var activationObserver: NSObjectProtocol?

    private struct ContextualSession {
        let id: UUID
        let sourcePID: pid_t
        let urls: [URL]
        let mode: TangerineMode
        let anchor: NSPoint
    }

    public convenience init() {
        self.init(engine: FileToolsBridge())
    }

    init(
        engine: TangerineRunning,
        presentDashboard: (() -> Void)? = nil,
        presentCompactParameters: (([URL], TangerineOption) -> Void)? = nil,
        onSubmitted: (([TangerineJob]) -> Void)? = nil,
        selectionResolver: TangerineSelectionResolving? = nil,
        contextualPresenter: TangerineContextualPresenting? = nil,
        frontmostProvider: (() -> FileSelectionSource?)? = nil,
        anchorProvider: (() -> NSPoint)? = nil,
        frontmostPIDProvider: (() -> pid_t?)? = nil,
        runningPIDProbe: ((pid_t) -> Bool)? = nil,
        activateSource: ((pid_t) -> Void)? = nil,
        presentNotice: ((TangerineContextualNotice, NSPoint, (() -> Void)?) -> Void)? = nil,
        grantPermission: ((TangerineContextualNotice.Remedy) -> Void)? = nil,
        automationPreflight: (() -> Bool)? = nil,
        accessibilityPreflight: (() -> Bool)? = nil,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        revalidation: TangerineContextualRevalidation = .strict
    ) {
        self.engine = engine
        let jobs = TangerineJobCenter(engine: engine)
        self.jobs = jobs
        let dashboard = LazyDashboard(jobs: jobs)
        self.dashboard = dashboard
        compact = TangerineCompactAction(jobs: jobs, presentParameters: presentCompactParameters)
        self.presentDashboard = presentDashboard ?? { dashboard.window.present() }
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
        makeContextualPresenter = { TangerineContextualPanel() }
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

    private final class LazyDashboard {
        private let jobs: TangerineJobCenter
        private var loaded: TangerineDashboard?

        init(jobs: TangerineJobCenter) {
            self.jobs = jobs
        }

        var window: TangerineDashboard {
            if let loaded { return loaded }
            let created = TangerineDashboard(jobs: jobs)
            loaded = created
            return created
        }

        func closeIfLoaded() {
            loaded?.close()
        }
    }

    private final class NoticePanelBox {
        lazy var panel = TangerineContextualNoticePanel()
    }

    private func wire() {
        compact.onSubmitted = { [weak self] created in
            self?.submissionObserver?(created)
            self?.showToast(for: created)
        }
        jobs.addObserver("toast") { [weak self] in self?.toast.refresh() }
        if let contextualPresenter { bind(contextualPresenter) }
    }

    private func bind(_ target: TangerineContextualPresenting) {
        target.onCommit = { [weak self] sessionID, option in
            self?.handleContextualCommit(sessionID: sessionID, option: option)
        }
        target.onDismiss = { [weak self] sessionID, reason in
            self?.handleContextualDismiss(sessionID: sessionID, reason: reason)
        }
    }

    @discardableResult
    func performSelectionAction(urls: [URL], option: TangerineOption) -> Bool {
        guard !urls.isEmpty else { return false }
        compact.perform(inputs: urls, option: option)
        return true
    }

    private var presenter: TangerineContextualPresenting {
        if let contextualPresenter { return contextualPresenter }
        let created = makeContextualPresenter()
        bind(created)
        contextualPresenter = created
        return created
    }

    private var resolver: TangerineSelectionResolving {
        if let selectionResolver { return selectionResolver }
        let created = makeSelectionResolver()
        selectionResolver = created
        return created
    }

    public func invokeSelection(mode: TangerineWheelMode = .convert) {
        invokeSelection(wheelMode: mode.mode)
    }

    func invokeSelection(wheelMode mode: TangerineMode) {
        let capturedSource = frontmostProvider()
        let anchor = anchorProvider()
        invalidateContextual(reason: .reinvoked)
        guard let capturedSource else {
            show(TangerineContextualNoticeFactory.notice(for: .noFrontmostApplication, source: nil), at: anchor)
            return
        }
        guard capturedSource.pid != ownPID else {
            show(TangerineContextualNoticeFactory.ownApplicationNotice, at: anchor)
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
        mode: TangerineMode,
        anchor: NSPoint
    ) {
        guard epoch == contextualEpoch else { return }
        let source = resolution.source
        guard source?.pid == expected.pid else {
            show(TangerineContextualNoticeFactory.notice(for: .sourceChanged, source: source), at: anchor)
            return
        }
        if let failure = resolution.failure {
            show(TangerineContextualNoticeFactory.notice(for: failure, source: source), at: anchor)
            return
        }
        let urls = resolution.selectedURLs
        guard !urls.isEmpty else {
            let notice = resolution.hasDocumentCandidate
                ? TangerineContextualNoticeFactory.documentOnlyNotice(source: source)
                : TangerineContextualNoticeFactory.notice(
                    for: resolution.selectionAvailability == .unsupported ? .unsupported : .noSelection,
                    source: source
                )
            show(notice, at: anchor)
            return
        }
        let groups = compact.groups(for: urls, mode: mode)
        guard !groups.isEmpty else {
            show(TangerineContextualNoticeFactory.noActionsNotice(urls: urls), at: anchor)
            return
        }
        let invocation = TangerineContextualInvocation(
            urls: urls,
            mode: mode,
            sourcePID: expected.pid,
            anchor: anchor,
            groups: groups,
            headline: Self.headline(urls)
        )
        contextualSession = ContextualSession(
            id: invocation.id,
            sourcePID: expected.pid,
            urls: urls,
            mode: mode,
            anchor: anchor
        )
        guard presenter.present(invocation) else {
            contextualSession = nil
            show(TangerineContextualNoticeFactory.noActionsNotice(urls: urls), at: anchor)
            return
        }
    }

    static func headline(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) arquivos"
    }

    func handleContextualDismiss(sessionID: UUID, reason: TangerineContextualDismissReason) {
        guard let session = contextualSession, session.id == sessionID else { return }
        contextualSession = nil
        contextualEpoch += 1
        guard reason != .commit else { return }
        restoreFocus(to: session.sourcePID)
    }

    func handleContextualCommit(sessionID: UUID, option: TangerineOption) {
        guard let session = contextualSession, session.id == sessionID else { return }
        contextualSession = nil
        contextualEpoch += 1
        let epoch = contextualEpoch
        let urls = session.urls
        restoreFocus(to: session.sourcePID)
        guard jobs.blocker(option: option, inputs: urls) == nil else {
            show(TangerineContextualNoticeFactory.staleSelectionNotice, at: session.anchor)
            return
        }
        guard revalidation == .strict else {
            performSelectionAction(urls: urls, option: option)
            return
        }
        resolver.resolve { [weak self] resolution in
            guard let self else { return }
            self.onMain {
                guard epoch == self.contextualEpoch else { return }
                if let failure = resolution.failure {
                    self.show(
                        TangerineContextualNoticeFactory.revalidationNotice(
                            for: failure,
                            source: resolution.source
                        ),
                        at: session.anchor
                    )
                    return
                }
                guard resolution.source?.pid == session.sourcePID,
                      TangerineContextualFileKeys.matches(resolution.selectedURLs, urls)
                else {
                    self.show(TangerineContextualNoticeFactory.staleSelectionNotice, at: session.anchor)
                    return
                }
                self.performSelectionAction(urls: urls, option: option)
            }
        }
    }

    func handleApplicationActivation(pid: pid_t) {
        guard let session = contextualSession else { return }
        guard TangerineContextualFocus.shouldInvalidate(
            activatedPID: pid,
            sourcePID: session.sourcePID,
            ownPID: ownPID
        ) else { return }
        invalidateContextual(reason: .sourceChanged)
    }

    func invalidateContextual(reason: TangerineContextualDismissReason) {
        contextualSession = nil
        contextualEpoch += 1
        contextualPresenter?.dismiss(reason: reason)
    }

    private func restoreFocus(to sourcePID: pid_t) {
        guard TangerineContextualFocus.shouldRestore(
            sourcePID: sourcePID,
            frontmostPID: frontmostPIDProvider(),
            ownPID: ownPID,
            sourceRunning: runningPIDProbe(sourcePID)
        ) else { return }
        activateSource(sourcePID)
    }

    private func show(_ notice: TangerineContextualNotice, at anchor: NSPoint) {
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
        return "Selecione arquivos no Finder ou na Mesa e chame a roda pelo atalho; a ação escolhida roda no mesmo backend do Tangerine.\n\nAutomação (Finder): \(automation)\nAcessibilidade (outros apps): \(accessibility)\(keyboard)\n\nAs permissões só são pedidas ao clicar nos botões abaixo."
    }

    func handleSelectionSettingsResponse(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            grantPermission(.automation(TangerineContextualNoticeFactory.finderBundleIdentifier))
        case .alertSecondButtonReturn:
            grantPermission(.accessibility)
        default:
            break
        }
    }

    var contextualSessionID: UUID? { contextualSession?.id }

    var contextualSelection: [URL] { contextualSession?.urls ?? [] }

    private func showToast(for created: [TangerineJob]) {
        guard !created.isEmpty else { return }
        toast.show(
            jobs: created,
            onCancel: { [weak self] batch in batch.forEach { self?.jobs.cancel($0) } },
            onOpenPanel: { [weak self] in self?.showSettings() }
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

    public func showSettings() {
        presentDashboard()
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
        dashboard.closeIfLoaded()
    }

    public var isRunning: Bool { running }

    public var activeJobs: Int { jobs.jobs.filter { $0.state == .running }.count }
}
