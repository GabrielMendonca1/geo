import AppKit

final class FilesCompactAction {
    enum Result: Equatable {
        case rejected
        case submitted(Int)
        case awaitingParameters
    }

    private let jobs: FilesJobCenter
    private let injectedPresenter: (([URL], FilesOption) -> Void)?
    var onSubmitted: (([FilesJob]) -> Void)?

    private var panel: FilesCompactPanel?

    init(
        jobs: FilesJobCenter,
        presentParameters: (([URL], FilesOption) -> Void)? = nil
    ) {
        self.jobs = jobs
        injectedPresenter = presentParameters
    }

    static func accepts(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { $0.isFileURL && $0.path.hasPrefix("/") }
    }

    func groups(for urls: [URL], mode: FilesMode) -> [FilesGroup] {
        guard Self.accepts(urls), let first = urls.first else { return [] }
        let capability = jobs.capability(for: urls)
        let category = FilesCategory.of(first) ?? .documents
        let extensions = Set(urls.map { FilesCatalog.normalize($0.pathExtension) })
        let sourceExtension = extensions.count == 1 ? (extensions.first ?? "") : ""
        switch mode {
        case .convert:
            return FilesCatalog.convertGroups(
                category: category,
                sourceExtension: sourceExtension,
                capability: capability
            )
        case .tools:
            return FilesCatalog.toolGroups(category: category, capability: capability)
                + FilesCatalog.batchGroups(
                    category: category,
                    inputCount: urls.count,
                    capability: capability
                )
        }
    }

    @discardableResult
    func perform(inputs: [URL], option: FilesOption) -> Result {
        guard Self.accepts(inputs), jobs.rejects(option: option, inputs: inputs).isEmpty else {
            return .rejected
        }
        if option.needsParams {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let presenter = self.injectedPresenter {
                    presenter(inputs, option)
                } else {
                    if self.panel == nil {
                        self.panel = FilesCompactPanel(jobs: self.jobs) { [weak self] created in
                            self?.onSubmitted?(created)
                        }
                    }
                    self.panel?.present(inputs: inputs, option: option)
                }
            }
            return .awaitingParameters
        }
        let created = jobs.submit(inputs: inputs, option: option, values: [:])
        guard !created.isEmpty else { return .rejected }
        RadialMenuView.playSelectionFeedback?()
        onSubmitted?(created)
        return .submitted(created.count)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private final class FilesCompactPanel: NSObject, NSWindowDelegate {
    private let jobs: FilesJobCenter
    private let onSubmitted: ([FilesJob]) -> Void
    private let window: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let filesLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let form = NSView(frame: .zero)
    private var inputs: [URL] = []
    private var option: FilesOption?
    private var fields: [String: NSTextField] = [:]
    private var choices: [String: NSPopUpButton] = [:]

    init(jobs: FilesJobCenter, onSubmitted: @escaping ([FilesJob]) -> Void) {
        self.jobs = jobs
        self.onSubmitted = onSubmitted
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 260),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Arquivos"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
    }

    func present(inputs: [URL], option: FilesOption) {
        self.inputs = inputs
        self.option = option
        rebuild()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(firstEditableControl())
    }

    func close() {
        window.orderOut(nil)
        inputs = []
        option = nil
        fields.removeAll()
        choices.removeAll()
    }

    private func rebuild() {
        guard let option else { return }
        let rowHeight: CGFloat = 34
        let formHeight = CGFloat(option.params.count) * rowHeight
        let height = max(230, 150 + formHeight)
        window.setContentSize(NSSize(width: 390, height: height))
        guard let content = window.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        fields.removeAll()
        choices.removeAll()
        form.subviews.forEach { $0.removeFromSuperview() }

        titleLabel.stringValue = option.title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: height - 39, width: 350, height: 22)
        content.addSubview(titleLabel)

        filesLabel.stringValue = inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) arquivos · ordem preservada"
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.font = .systemFont(ofSize: 11)
        filesLabel.frame = NSRect(x: 20, y: height - 62, width: 350, height: 18)
        content.addSubview(filesLabel)

        form.frame = NSRect(x: 20, y: 69, width: 350, height: formHeight)
        content.addSubview(form)
        for (index, param) in option.params.enumerated() {
            let y = formHeight - CGFloat(index + 1) * rowHeight
            let label = NSTextField(labelWithString: param.label)
            label.frame = NSRect(x: 0, y: y + 7, width: 116, height: 18)
            form.addSubview(label)
            switch param.kind {
            case .choice(let values):
                let popup = NSPopUpButton(frame: NSRect(x: 122, y: y + 2, width: 228, height: 26))
                popup.addItems(withTitles: values.map(\.label))
                if let selected = values.firstIndex(where: { $0.value == param.fallback }) {
                    popup.selectItem(at: selected)
                }
                choices[param.id] = popup
                form.addSubview(popup)
            default:
                let field = NSTextField(frame: NSRect(x: 122, y: y + 3, width: 228, height: 24))
                field.stringValue = param.fallback
                field.placeholderString = param.hint
                fields[param.id] = field
                form.addSubview(field)
            }
        }

        statusLabel.stringValue = ""
        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: 45, width: 238, height: 20)
        content.addSubview(statusLabel)

        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 205, y: 14, width: 78, height: 30)
        content.addSubview(cancel)
        let apply = NSButton(title: "Aplicar", target: self, action: #selector(applyPressed))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: 288, y: 14, width: 82, height: 30)
        content.addSubview(apply)
    }

    private func firstEditableControl() -> NSView? {
        guard let option else { return nil }
        for param in option.params {
            if let field = fields[param.id] { return field }
            if let choice = choices[param.id] { return choice }
        }
        return nil
    }

    private enum ParsedValues {
        case success([String: FilesValue])
        case failure(String)
    }

    private func parsedValues() -> ParsedValues {
        guard let option else { return .failure("Ação indisponível.") }
        var result: [String: FilesValue] = [:]
        for param in option.params {
            let raw: String
            if let popup = choices[param.id] {
                let index = popup.indexOfSelectedItem
                raw = index >= 0 && index < param.choices.count ? param.choices[index].value : ""
            } else {
                raw = fields[param.id]?.stringValue ?? param.fallback
            }
            switch param.parse(raw) {
            case .value(let value): result[param.id] = value
            case .problem(let message): return .failure(message)
            }
        }
        if let problem = FilesCatalog.batchProblem(option: option, values: result, inputCount: inputs.count) {
            return .failure(problem)
        }
        return .success(result)
    }

    @objc private func applyPressed() {
        guard let option else { return }
        switch parsedValues() {
        case .failure(let message):
            statusLabel.stringValue = message
        case .success(let values):
            guard jobs.blocker(option: option, inputs: inputs) == nil else {
                statusLabel.stringValue = "A ação não serve mais a esta seleção."
                return
            }
            let created = jobs.submit(inputs: inputs, option: option, values: values)
            guard !created.isEmpty else { return }
            RadialMenuView.playSelectionFeedback?()
            onSubmitted(created)
            close()
        }
    }

    @objc private func cancelPressed() { close() }
    func windowWillClose(_ notification: Notification) { close() }
}
