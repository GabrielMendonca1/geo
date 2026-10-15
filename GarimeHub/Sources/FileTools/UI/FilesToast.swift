import AppKit

final class FilesToast {
    private let panel: NSPanel
    private let card = FilesCard(frame: NSRect(x: 0, y: 0, width: 340, height: 76))
    private let title = FilesTheme.label("", size: 12.5, weight: .semibold)
    private let subtitle = FilesTheme.label("", size: 11, weight: .regular, color: FilesTheme.inkSoft)
    private let spinner = NSProgressIndicator(frame: NSRect(x: 14, y: 30, width: 16, height: 16))
    private let actionPill: FilesPill
    private var hideWork: DispatchWorkItem?

    private var batch: [FilesJob] = []
    private var onCancel: (([FilesJob]) -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)
        actionPill = FilesPill(frame: NSRect(x: 236, y: 42, width: 90, height: 24), title: "Mostrar", handler: {})

        card.autoresizingMask = [.width, .height]
        panel.contentView = card
        title.frame = NSRect(x: 38, y: 14, width: 288, height: 17)
        subtitle.frame = NSRect(x: 38, y: 33, width: 288, height: 16)
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        card.addSubview(title)
        card.addSubview(subtitle)
        card.addSubview(spinner)
        card.addSubview(actionPill)
        actionPill.isHidden = true
    }

    func show(
        jobs: [FilesJob],
        onCancel: @escaping ([FilesJob]) -> Void
    ) {
        guard !jobs.isEmpty else { return }
        batch = jobs
        self.onCancel = onCancel
        refresh()
        position()
        panel.orderFrontRegardless()
    }

    private func summary() -> (title: String, subtitle: String, failed: Bool) {
        guard let first = batch.first else { return ("", "", false) }
        guard batch.count > 1 else { return (first.title, first.subtitle, first.state == .failed) }
        let running = batch.filter { $0.state == .running }.count
        let done = batch.filter { $0.state == .done }.count
        let failed = batch.filter { $0.state == .failed }.count
        let cancelled = batch.filter { $0.state == .cancelled }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) em andamento") }
        if done > 0 { parts.append("\(done) prontos") }
        if failed > 0 { parts.append("\(failed) com falha") }
        if cancelled > 0 { parts.append("\(cancelled) cancelados") }
        let detail = failed > 0
            ? (batch.first { $0.state == .failed }?.subtitle).map { " · \($0)" } ?? ""
            : ""
        return (
            "\(first.option.title) · \(batch.count) arquivos",
            parts.joined(separator: " · ") + detail,
            failed > 0
        )
    }

    func refresh() {
        let anyRunning = batch.contains { $0.state == .running }
        guard !batch.isEmpty, panel.isVisible || anyRunning else { return }
        let state = summary()
        title.stringValue = state.title
        subtitle.stringValue = state.subtitle
        subtitle.toolTip = state.subtitle
        subtitle.textColor = state.failed ? FilesTheme.danger : FilesTheme.inkSoft

        if anyRunning {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            actionPill.isHidden = false
            actionPill.selected = false
            actionPill.title = "Cancelar"
            actionPill.action = { [weak self] in
                guard let self else { return }
                self.onCancel?(self.batch.filter { $0.state == .running })
            }
            cancelHide()
            card.needsDisplay = true
            return
        }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        if state.failed {
            actionPill.isHidden = false
            actionPill.selected = false
            actionPill.title = "Detalhes"
            let failures = batch.filter { $0.state == .failed }.map { "\($0.title): \($0.subtitle)" }
            actionPill.action = { [weak self] in self?.showFailures(failures) }
            scheduleHide(after: 12)
        } else {
            let outputs = batch.flatMap { $0.outputs }
            actionPill.isHidden = outputs.isEmpty
            actionPill.selected = true
            actionPill.title = "Mostrar"
            actionPill.action = {
                guard !outputs.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
            scheduleHide(after: batch.contains { $0.state == .done } ? 6 : 3)
        }
        card.needsDisplay = true
    }

    private func position() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: frame.maxX - 360, y: frame.maxY - 96, width: 340, height: 76),
            display: true
        )
    }

    private func scheduleHide(after seconds: TimeInterval) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func showFailures(_ failures: [String]) {
        cancelHide()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1 ? "A ação falhou" : "\(failures.count) arquivos falharam"
        alert.informativeText = failures.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copiar")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failures.joined(separator: "\n"), forType: .string)
        }
        hide()
    }

    func hide() {
        cancelHide()
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        batch = []
    }
}
