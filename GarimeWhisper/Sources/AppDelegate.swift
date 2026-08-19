import AppKit

enum Phase: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case flushing
    case done(String)
    case failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var icon: StatusIcon!
    private var menuController: MenuController!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let paster = Paster()
    private let typist = Typist()
    private let focusGate = SystemFocusGate()
    private let insomnia = InsomniaController()
    private let meeting = MeetingController()
    private var meetingDirectory: URL?
    private let call = CallController()
    private var callDirectory: String?
    private let capture = CaptureWatcher()
    private var captureLine: String?
    private let tasksController = TasksController()

    private var phase: Phase = .idle
    private var generation = 0
    private var autoStop: DispatchWorkItem?
    private var resetIcon: DispatchWorkItem?
    private var blockingError: String?
    private var awaitingMicrophone = false

    private var session: DictationSession?
    private var decoder: WindowedDecoder?
    private var streamingLost = false
    private var lastLevelAt = Date()
    private var meter = LevelMeter(
        attack: Config.meterAttack,
        release: Config.meterRelease,
        floorDecibels: Config.meterFloorDecibels,
        holdSeconds: Config.meterPeakHoldSeconds
    )

    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let insomniaItem = NSMenuItem(title: "Manter acordado", action: nil, keyEquivalent: "")
    private let meetingToggleItem = NSMenuItem(title: "Gravar reunião", action: nil, keyEquivalent: "")
    private let meetingStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let callToggleItem = NSMenuItem(title: "Gravar call", action: nil, keyEquivalent: "")
    private let callStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hubPanel = HubPanel()
    private var openProject: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        icon = StatusIcon()
        buildMenu()

        recorder.onRouteChange = { [weak self] in
            guard let self, case .recording = self.phase else { return }
            self.recorder.abort()
            self.fail(RecorderError.routeChanged.localizedDescription)
        }

        recorder.onLevel = { [weak self] rms, peak in
            guard let self else { return }
            let now = Date()
            let elapsed = max(0, now.timeIntervalSince(self.lastLevelAt))
            self.lastLevelAt = now
            self.meter.ingest(rms: rms, peak: peak, elapsed: elapsed)
            self.icon.updateLevel(self.meter.level, peak: self.meter.peak)
        }

        meeting.onChange = { [weak self] in self?.meetingChanged() }

        call.onChange = { [weak self] in self?.callChanged() }
        call.start()

        capture.onProcessed = { [weak self] in self?.icon.flash("camera.fill") }
        capture.onCondition = { [weak self] condition in self?.captureChanged(condition) }
        capture.start()

        tasksController.onChange = { [weak self] in self?.tasksChanged() }
        tasksController.start()

        Hotkey.shared.onTrigger = { [weak self] in self?.toggle() }
        if !Hotkey.shared.register() {
            blockingError = "⌥Space já está em uso — use o menu para ditar"
        }
        if let missing = Preflight.missingDependency() {
            blockingError = missing
        }

        if blockingError != nil {
            icon.apply(.error)
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        insomnia.deactivate()
        meeting.abort()
        call.stop()
        capture.stop()
        tasksController.stop()
        session?.cancel()
        decoder?.cancel()
        recorder.abort()
        transcriber.cancel()
    }

    private func buildMenu() {
        menuController = MenuController(menu: icon.menu)

        statusItem.isEnabled = false

        toggleItem.target = self
        toggleItem.action = #selector(menuToggle)

        accessibilityItem.target = self
        accessibilityItem.action = #selector(menuAccessibility)
        accessibilityItem.title = "Ativar colagem automática…"

        insomniaItem.target = self
        insomniaItem.action = #selector(menuInsomnia)

        meetingToggleItem.target = self
        meetingToggleItem.action = #selector(menuMeeting)
        meetingStatusItem.isHidden = true

        callToggleItem.target = self
        callToggleItem.action = #selector(menuCall)
        callStatusItem.isHidden = true

        icon.menu.delegate = self
        icon.onPrimaryClick = { [weak self] in self?.togglePanel() }

        let quit = NSMenuItem(title: "Sair", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self

        menuController.set(.status, items: [statusItem])
        menuController.set(.dictation, items: [toggleItem, accessibilityItem])
        menuController.set(.meeting, items: [meetingToggleItem, meetingStatusItem, callToggleItem, callStatusItem])
        menuController.set(.insomnia, items: [insomniaItem])
        menuController.set(.app, items: [quit])
    }

    private func refreshMenu() {
        statusItem.title = statusText()
        switch phase {
        case .recording: toggleItem.title = "Parar e transcrever (⌥Space)"
        case .transcribing, .flushing: toggleItem.title = "Cancelar (⌥Space)"
        default: toggleItem.title = "Ditar (⌥Space)"
        }
        accessibilityItem.isHidden = paster.accessibilityTrusted
    }

    private func statusText() -> String {
        if let blockingError { return "Erro: \(blockingError)" }
        switch phase {
        case .idle: return "Pronto"
        case .starting: return "Preparando…"
        case .recording: return recordingStatus()
        case .transcribing: return "Transcrevendo…"
        case .flushing: return "Finalizando…"
        case .done(let detail): return detail
        case .failed(let detail): return "Erro: \(detail)"
        }
    }

    private func recordingStatus() -> String {
        guard let session else { return "Gravando…" }
        if let reason = session.latch { return "Gravando — \(reason.message)" }
        let words = session.typedText.split(whereSeparator: \.isWhitespace).count
        return words > 0 ? "Ditando — \(words) palavras" : "Gravando…"
    }

    @objc private func menuToggle() { toggle() }

    @objc private func menuCall() {
        if call.isRecording {
            call.finish()
            return
        }
        if meeting.isRecording {
            icon.flash("mic.slash.fill")
            return
        }
        switch phase {
        case .idle, .done, .failed:
            break
        default:
            icon.flash("mic.slash.fill")
            return
        }
        call.begin()
    }

    @objc private func menuOpenCall() {
        guard let callDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: callDirectory))
    }

    private func callChanged() {
        switch call.state {
        case .idle:
            callToggleItem.title = "Gravar call"
            callStatusItem.isHidden = true
            callStatusItem.action = nil
            restoreIdleIconAfterMeeting()
        case .recording:
            callToggleItem.title = "Parar call"
            callStatusItem.isHidden = true
            callStatusItem.action = nil
            icon.apply(.meeting)
        case .stopping:
            callToggleItem.title = "Parando…"
            callStatusItem.isHidden = false
            callStatusItem.action = nil
            callStatusItem.title = "Transcrevendo call…"
            restoreIdleIconAfterMeeting()
        case .done(let directory):
            callDirectory = directory
            callToggleItem.title = "Gravar call"
            callStatusItem.isHidden = false
            callStatusItem.target = self
            callStatusItem.action = #selector(menuOpenCall)
            callStatusItem.title = "Call pronta — abrir pasta"
            icon.flash("checkmark.circle.fill")
        case .failed(let message):
            callToggleItem.title = "Gravar call"
            callStatusItem.isHidden = false
            callStatusItem.action = nil
            callStatusItem.title = "Erro na call: \(message)"
            restoreIdleIconAfterMeeting()
        }
        refreshMenu()
    }

    @objc private func menuMeeting() {
        if meeting.isRecording {
            meeting.stop()
            return
        }
        if call.isRecording {
            icon.flash("mic.slash.fill")
            return
        }
        switch phase {
        case .idle, .done, .failed:
            break
        default:
            icon.flash("mic.slash.fill")
            return
        }
        guard !recorder.isRecording, !awaitingMicrophone else { return }
        meeting.begin()
    }

    @objc private func menuOpenMeeting() {
        guard let meetingDirectory else { return }
        NSWorkspace.shared.open(meetingDirectory)
    }

    private func meetingChanged() {
        switch meeting.state {
        case .idle:
            meetingToggleItem.title = "Gravar reunião"
            meetingStatusItem.isHidden = true
            meetingStatusItem.action = nil
            restoreIdleIconAfterMeeting()
        case .recording:
            let minutes = meeting.elapsedMinutes()
            meetingToggleItem.title = minutes > 0
                ? "Parar reunião (\(minutes) min)"
                : "Parar reunião"
            meetingStatusItem.isHidden = true
            meetingStatusItem.action = nil
            icon.apply(.meeting)
        case .transcribing:
            meetingToggleItem.title = "Gravar reunião"
            meetingStatusItem.isHidden = false
            meetingStatusItem.action = nil
            meetingStatusItem.title = "Transcrevendo reunião…"
            restoreIdleIconAfterMeeting()
        case .done(let directory):
            meetingDirectory = directory
            meetingToggleItem.title = "Gravar reunião"
            meetingStatusItem.isHidden = false
            meetingStatusItem.target = self
            meetingStatusItem.action = #selector(menuOpenMeeting)
            meetingStatusItem.title = "Reunião pronta — abrir pasta"
            icon.flash("checkmark.circle.fill")
        case .failed(let message):
            meetingToggleItem.title = "Gravar reunião"
            meetingStatusItem.isHidden = false
            meetingStatusItem.action = nil
            meetingStatusItem.title = "Erro na reunião: \(message)"
            restoreIdleIconAfterMeeting()
        }
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === icon.menu else { return }
        tasksController.refreshIfStale()
    }

    @objc private func panelActions() {
        hubPanel.close()
        icon.popUpActions()
    }

    private func togglePanel() {
        if hubPanel.isOpen {
            hubPanel.close()
            return
        }
        openProject = nil
        tasksController.refreshIfStale()
        presentPanel()
    }

    private func presentPanel() {
        hubPanel.show(content: panelContent(), below: icon.button)
    }

    private func panelFooter() -> String {
        if let fetchedAt = tasksController.fetchedAt {
            let age = VaultTasks.age(from: fetchedAt, to: Date())
            return tasksController.offline
                ? "offline — cache de \(age)"
                : "atualizado \(age)"
        }
        return tasksController.offline ? "offline — sem cache" : "carregando…"
    }

    private func panelActionSpecs() -> [HubActionSpec] {
        [
            HubActionSpec(
                action: .dictate,
                symbol: phase == .recording ? "mic.fill" : "mic",
                tooltip: "Ditar (⌥Space)",
                on: phase == .recording
            ),
            HubActionSpec(
                action: .meeting,
                symbol: "record.circle",
                tooltip: meeting.isRecording ? "Parar reunião" : "Gravar reunião",
                on: meeting.isRecording
            ),
            HubActionSpec(
                action: .call,
                symbol: "phone",
                tooltip: call.isRecording ? "Parar call" : "Gravar call",
                on: call.isRecording
            ),
            HubActionSpec(
                action: .insomnia,
                symbol: "moon",
                tooltip: "Manter acordado",
                on: insomnia.isActive
            ),
            HubActionSpec(
                action: .notes,
                symbol: "book.closed",
                tooltip: "Abrir o Vault",
                on: false
            ),
        ]
    }

    private func panelContent() -> NSView {
        let projects = ProjectStatusScanner.scan(roots: Config.projectRoots)
        let content: HubContent
        if let openProject, let project = projects.first(where: { $0.path == openProject }) {
            content = HubContent(
                headerStrong: project.name,
                headerRest: "",
                back: true,
                sections: [HubModel.todosSection(project, titleLimit: Config.taskTitleLimit)],
                notice: nil,
                footer: project.updated.map { "atualizado: \($0)" } ?? "sem carimbo de data",
                actions: panelActionSpecs()
            )
        } else {
            let header = HubModel.dateHeader(Date(), locale: Locale(identifier: "pt_BR"))
            content = HubContent(
                headerStrong: header.0,
                headerRest: header.1,
                back: false,
                sections: [
                    HubModel.tasksSection(
                        VaultTasks.open(tasksController.tasks),
                        limit: Config.tasksMenuLimit,
                        titleLimit: Config.taskTitleLimit
                    ),
                    HubModel.projectsSection(
                        projects,
                        limit: Config.panelProjectLimit,
                        titleLimit: Config.taskTitleLimit
                    ),
                ],
                notice: captureLine,
                footer: panelFooter(),
                actions: panelActionSpecs()
            )
        }
        return HubPanelView.build(
            content: content,
            onRow: { [weak self] id in self?.panelOpenRow(id) },
            onCheck: { [weak self] id in self?.panelCheck(id) },
            onBack: { [weak self] in
                self?.openProject = nil
                self?.presentPanel()
            },
            onAction: { [weak self] action in self?.panelRun(action) },
            onMore: { [weak self] in self?.panelActions() }
        )
    }

    private func panelOpenRow(_ id: String) {
        guard id.hasPrefix("project:") else { return }
        let path = String(id.dropFirst("project:".count))
        guard path != "more" else { return }
        openProject = path
        presentPanel()
    }

    private func panelCheck(_ id: String) {
        guard id.hasPrefix("todo:"), let path = openProject else { return }
        let todo = String(id.dropFirst("todo:".count))
        if StatusTodoWriter.complete(path: path, todo: todo) {
            icon.flash("checkmark.circle.fill")
        }
        presentPanel()
    }

    private func panelRun(_ action: HubAction) {
        switch action {
        case .dictate:
            hubPanel.close()
            menuToggle()
        case .meeting:
            hubPanel.close()
            menuMeeting()
        case .call:
            hubPanel.close()
            menuCall()
        case .insomnia:
            menuInsomnia()
            presentPanel()
        case .notes:
            hubPanel.close()
            NSWorkspace.shared.open(URL(fileURLWithPath: Config.vaultDirectory))
        case .quit:
            menuQuit()
        }
    }

    private func tasksChanged() {
        guard hubPanel.isOpen else { return }
        hubPanel.show(content: panelContent(), below: icon.button)
    }

    private func captureChanged(_ condition: CaptureCondition) {
        let line = CaptureProbe.line(for: condition)
        icon.setOverlay(.alert, enabled: line != nil)
        guard line != captureLine else { return }
        captureLine = line
        if let line {
            captureItem.title = line
            menuController.set(.capture, items: [captureItem])
        } else {
            menuController.set(.capture, items: [])
        }
    }

    private func restoreIdleIconAfterMeeting() {
        guard !meeting.isRecording, !call.isRecording else { return }
        if case .idle = phase {
            icon.apply(.idle)
        }
    }

    @objc private func menuInsomnia() {
        insomnia.toggle()
        insomniaItem.state = insomnia.isActive ? .on : .off
        icon.setOverlay(.moon, enabled: insomnia.isActive)
    }

    @objc private func menuAccessibility() {
        paster.requestAccessibilityOnce()
        paster.openAccessibilitySettings()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func toggle() {
        if meeting.isRecording || call.isRecording {
            icon.flash("mic.slash.fill")
            return
        }
        if let missing = Preflight.missingDependency() {
            blockingError = missing
            fail(missing)
            return
        }
        blockingError = nil

        switch phase {
        case .recording:
            finishRecording()
        case .transcribing, .flushing:
            cancelTranscription()
        case .starting:
            break
        case .idle, .done, .failed:
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !awaitingMicrophone, !recorder.isRecording else { return }
        awaitingMicrophone = true
        enter(.starting, icon: .starting)
        Recorder.microphoneAuthorized { [weak self] granted in
            guard let self else { return }
            self.awaitingMicrophone = false
            guard granted else {
                self.fail(RecorderError.microphoneDenied.localizedDescription)
                return
            }
            switch self.phase {
            case .recording, .transcribing, .flushing: return
            default: break
            }
            do {
                try self.recorder.start()
            } catch {
                self.fail(error.localizedDescription)
                return
            }
            self.generation += 1
            let token = self.generation
            self.meter.reset()
            self.lastLevelAt = Date()
            self.streamingLost = false
            self.startStreaming(token: token)
            self.enter(.recording, icon: .recording)

            let stopper = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token, case .recording = self.phase else { return }
                self.finishRecording()
            }
            self.autoStop = stopper
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Config.maxRecordingSeconds,
                execute: stopper
            )
        }
    }

    private func startStreaming(token: Int) {
        teardownStreaming()
        guard Config.streamingEnabled else { return }

        let candidate = DictationSession(generation: token, sink: typist, gate: focusGate)
        guard candidate.begin() else {
            paster.requestAccessibilityOnce()
            return
        }

        let engine = WindowedDecoder(
            source: recorder.stream,
            backend: WhisperBackend(),
            tuning: .standard
        )
        engine.onDelta = { [weak self] delta in
            guard let self, let active = self.session, active.generation == token else { return }
            guard self.generation == token else { return }
            _ = active.ingest(delta, generation: token)
            self.refreshMenu()
        }
        engine.onStreamingLost = { [weak self] in
            guard let self, self.generation == token else { return }
            self.streamingLost = true
        }
        session = candidate
        decoder = engine
        engine.start()
    }

    private func finishRecording() {
        autoStop?.cancel()
        autoStop = nil
        guard let capture = recorder.stop() else {
            teardownStreaming()
            enter(.idle, icon: .idle)
            return
        }
        guard capture.duration >= Config.minRecordingSeconds else {
            try? FileManager.default.removeItem(at: capture.url)
            teardownStreaming()
            enter(.idle, icon: .idle)
            return
        }

        let token = generation
        guard let engine = decoder, let active = session, active.generation == token else {
            teardownStreaming()
            runBatch(capture: capture)
            return
        }

        enter(.flushing, icon: .flushing)
        engine.finish { [weak self] tail, failed in
            guard let self, self.generation == token else {
                try? FileManager.default.removeItem(at: capture.url)
                return
            }
            self.completeStreaming(capture: capture, tail: tail, failed: failed, token: token)
        }
    }

    private func completeStreaming(
        capture: (url: URL, duration: TimeInterval),
        tail: String,
        failed: Bool,
        token: Int
    ) {
        guard let active = session, active.generation == token else {
            try? FileManager.default.removeItem(at: capture.url)
            return
        }

        let outcome = active.finish(tail: tail, generation: token)
        let typed = active.typedText
        let transcript = active.transcript

        if transcript.isEmpty {
            teardownStreaming()
            runBatch(capture: capture)
            return
        }
        if failed, !typed.isEmpty {
            teardownStreaming()
            runReviewBatch(capture: capture)
            return
        }

        try? FileManager.default.removeItem(at: capture.url)
        teardownStreaming()

        switch outcome {
        case .clipboard(let text, let reason):
            paster.copy(text, concealed: reason == .secure)
            enter(.done(reason.message), icon: .success)
        case .typed, .nothing, .duplicate:
            enter(.done("Digitado"), icon: .success)
        }
        scheduleIdle(after: 2.0)
    }

    private func runBatch(capture: (url: URL, duration: TimeInterval)) {
        generation += 1
        let token = generation
        enter(.transcribing, icon: .transcribing)

        transcriber.transcribe(source: capture.url) { [weak self] result in
            try? FileManager.default.removeItem(at: capture.url)
            guard let self, token == self.generation else { return }
            switch result {
            case .success(let text):
                self.handle(text)
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func runReviewBatch(capture: (url: URL, duration: TimeInterval)) {
        generation += 1
        let token = generation
        enter(.transcribing, icon: .transcribing)

        transcriber.transcribe(source: capture.url) { [weak self] result in
            try? FileManager.default.removeItem(at: capture.url)
            guard let self, token == self.generation else { return }
            switch result {
            case .success(let text):
                self.paster.copy(text)
                self.enter(.done("revisão no clipboard"), icon: .success)
                self.scheduleIdle(after: 3.0)
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func cancelTranscription() {
        generation += 1
        session?.cancel()
        decoder?.cancel()
        transcriber.cancel()
        recorder.abort()
        teardownStreaming()
        enter(.idle, icon: .cancelled)
    }

    private func teardownStreaming() {
        session = nil
        decoder?.cancel()
        decoder = nil
        focusGate.release()
    }

    private func handle(_ text: String) {
        switch paster.deliver(text) {
        case .pasted:
            enter(.done("Colado"), icon: .success)
        case .copiedOnly(let reason):
            enter(.done(reason), icon: .success)
        }
        scheduleIdle(after: 2.0)
    }

    private func fail(_ message: String) {
        session?.cancel()
        decoder?.cancel()
        teardownStreaming()
        recorder.abort()
        enter(.failed(message), icon: .error)
        scheduleIdle(after: 3.0)
    }

    private func enter(_ next: Phase, icon state: IconState) {
        switch next {
        case .recording: break
        default:
            autoStop?.cancel()
            autoStop = nil
        }
        phase = next
        icon.apply(state)
        refreshMenu()
    }

    private func scheduleIdle(after delay: TimeInterval) {
        resetIcon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .done, .failed:
                if let blockingError = self.blockingError {
                    self.enter(.failed(blockingError), icon: .error)
                } else {
                    self.enter(.idle, icon: .idle)
                }
            default:
                break
            }
        }
        resetIcon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
