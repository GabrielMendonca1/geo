import AppKit

final class TangerineDashboard: NSObject, NSWindowDelegate {
    private let jobs: TangerineJobCenter
    private let window: NSWindow
    private let root: DashboardRootView

    private let convertWheel = RadialMenuView(frame: .zero)
    private let toolsWheel = RadialMenuView(frame: .zero)
    private let convertCard = TangerineCard(frame: .zero)
    private let toolsCard = TangerineCard(frame: .zero)
    private let convertTitle = TangerineTheme.label("Converter formatos", size: 13, weight: .semibold)
    private let toolsTitle = TangerineTheme.label("Ferramentas avançadas", size: 13, weight: .semibold)
    private let convertCaps = TangerineKeycaps(caps: ["⇧", "shift"])
    private let toolsCaps = TangerineKeycaps(caps: ["⇧", "shift", "+", "⌥", "option"])
    private let convertHint = TangerineTheme.label(
        "clique num setor aplica · Tab troca de roda",
        size: 10.5,
        weight: .regular,
        color: TangerineTheme.inkFaint
    )
    private let toolsHint = TangerineTheme.label(
        "setas navegam · Enter aplica",
        size: 10.5,
        weight: .regular,
        color: TangerineTheme.inkFaint
    )

    private let titleLabel = TangerineTheme.label("Tangerine", size: 20, weight: .bold)
    private let subtitleLabel = TangerineTheme.label(
        "converta e ajuste arquivos localmente · Shift+arraste no Finder",
        size: 11.5,
        weight: .regular,
        color: TangerineTheme.inkFaint
    )
    private let coverageLabel = TangerineTheme.label("", size: 11, weight: .medium, color: TangerineTheme.inkFaint)
    private let choosePill: TangerinePill
    private let filesCard = TangerineCard(frame: .zero)
    private let jobsCard = TangerineCard(frame: .zero)
    private let filesHeader = TangerineTheme.label("Arquivos", size: 13, weight: .semibold)
    private let paramsHeader = TangerineTheme.label("Ajustes", size: 13, weight: .semibold)
    private let jobsHeader = TangerineTheme.label("Trabalhos", size: 13, weight: .semibold)
    private let clearPill: TangerinePill
    private let dropZone = DashboardDropView(frame: .zero)
    private let fileList = FlippedContainer(frame: .zero)
    private let fileScroll = NSScrollView(frame: .zero)
    private let paramsBox = FlippedContainer(frame: .zero)
    private let paramsScroll = NSScrollView(frame: .zero)
    private let jobsList = FlippedContainer(frame: .zero)
    private let jobsScroll = NSScrollView(frame: .zero)
    private let statusLabel = TangerineTheme.label("", size: 11.5, weight: .medium, color: TangerineTheme.inkSoft)
    private var tabPills: [TangerineCategory: TangerinePill] = [:]
    private let applyPill: TangerinePill

    private var inputs: [URL] = []
    private var category: TangerineCategory = .images
    private var mode: TangerineMode = .convert
    private var paramValues: [String: String] = [:]
    private var paramFields: [String: NSTextField] = [:]
    private var paramChoices: [String: NSPopUpButton] = [:]
    private var paramSwatches: [String: NSView] = [:]
    private var ticker: Timer?

    private var capability: TangerineCapability = .unknown

    static let minimumWidth: CGFloat = 1080
    static let minimumHeight: CGFloat = 780
    private let width: CGFloat = 1180
    private let height: CGFloat = 840

    init(jobs: TangerineJobCenter) {
        self.jobs = jobs
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        root = DashboardRootView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        choosePill = TangerinePill(frame: .zero, title: "Escolher arquivos…", handler: {})
        clearPill = TangerinePill(frame: .zero, title: "Limpar prontos", handler: {})
        applyPill = TangerinePill(frame: .zero, title: "Aplicar", handler: {})
        super.init()

        window.title = "Tangerine"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = TangerineTheme.panel
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.contentMinSize = NSSize(width: TangerineDashboard.minimumWidth, height: TangerineDashboard.minimumHeight)
        root.dashboard = self
        root.wantsLayer = true
        root.layer?.backgroundColor = TangerineTheme.panel.cgColor

        buildChrome()
        layoutChrome()
        jobs.addObserver("dashboard") { [weak self] in self?.renderJobs() }
        renderAll()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(root)
        startTicker()
        layoutChrome()
        renderAll()
    }

    func close() {
        window.orderOut(nil)
        stopTicker()
    }

    @discardableResult
    func load(inputs: [URL], option: TangerineOption, mode: TangerineMode) -> Bool {
        setInputs(inputs)
        self.mode = mode
        rebuildGroups()
        let available = selectOption(option)
        renderAll()
        return available
    }

    func present(inputs: [URL], option: TangerineOption, mode: TangerineMode) {
        let available = load(inputs: inputs, option: option, mode: mode)
        present()
        if available {
            status("Ajuste os parâmetros e toque em Aplicar.", warning: false)
        } else {
            status("\(option.title) não serve a todos os arquivos escolhidos.", warning: true)
        }
    }

    private func buildChrome() {
        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        coverageLabel.alignment = .right
        root.addSubview(coverageLabel)
        rewire(choosePill) { [weak self] in self?.chooseFiles() }
        root.addSubview(choosePill)

        for category in TangerineCategory.allCases {
            let pill = TangerinePill(frame: .zero, title: category.title) { [weak self] in
                self?.selectCategory(category)
            }
            root.addSubview(pill)
            tabPills[category] = pill
        }

        root.addSubview(filesCard)
        root.addSubview(convertCard)
        root.addSubview(toolsCard)
        root.addSubview(jobsCard)

        buildFilesCard()
        buildWheelCards()
        buildJobsCard()
    }

    private func buildFilesCard() {
        filesCard.addSubview(filesHeader)

        dropZone.onDrop = { [weak self] urls in self?.setInputs(urls) }
        filesCard.addSubview(dropZone)

        fileScroll.drawsBackground = false
        fileScroll.hasVerticalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.documentView = fileList
        filesCard.addSubview(fileScroll)

        filesCard.addSubview(paramsHeader)
        paramsScroll.drawsBackground = false
        paramsScroll.hasVerticalScroller = true
        paramsScroll.autohidesScrollers = true
        paramsScroll.documentView = paramsBox
        filesCard.addSubview(paramsScroll)

        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        filesCard.addSubview(statusLabel)

        filesCard.addSubview(applyPill)
        applyPill.selected = true
        applyPill.enabledAction = false
        rewire(applyPill) { [weak self] in self?.runSelection() }
    }

    private func buildWheelCards() {
        convertWheel.mode = .convert
        toolsWheel.mode = .tools
        for (card, wheelView, title, caps, hint) in [
            (convertCard, convertWheel, convertTitle, convertCaps, convertHint),
            (toolsCard, toolsWheel, toolsTitle, toolsCaps, toolsHint),
        ] {
            card.addSubview(title)
            card.addSubview(caps)
            hint.alignment = .center
            card.addSubview(hint)
            card.addSubview(wheelView)
        }
        convertWheel.onSelectionChange = { [weak self] _ in self?.focus(.convert) }
        toolsWheel.onSelectionChange = { [weak self] _ in self?.focus(.tools) }
        convertWheel.onCommit = { [weak self] _ in
            self?.focus(.convert)
            self?.runSelection()
        }
        toolsWheel.onCommit = { [weak self] _ in
            self?.focus(.tools)
            self?.runSelection()
        }
    }

    private func buildJobsCard() {
        jobsCard.addSubview(jobsHeader)
        rewire(clearPill) { [weak self] in self?.jobs.clearFinished() }
        jobsCard.addSubview(clearPill)

        jobsScroll.drawsBackground = false
        jobsScroll.hasVerticalScroller = true
        jobsScroll.autohidesScrollers = true
        jobsScroll.documentView = jobsList
        jobsCard.addSubview(jobsScroll)
    }

    func layoutChrome() {
        let full = root.bounds
        let w = max(full.width, TangerineDashboard.minimumWidth)
        let h = max(full.height, TangerineDashboard.minimumHeight)

        titleLabel.frame = NSRect(x: 24, y: 16, width: 260, height: 26)
        subtitleLabel.frame = NSRect(x: 24, y: 44, width: max(w - 260, 200), height: 16)
        choosePill.frame = NSRect(x: w - 200, y: 22, width: 176, height: 30)

        var x: CGFloat = 24
        for category in TangerineCategory.allCases {
            tabPills[category]?.frame = NSRect(x: x, y: 76, width: 112, height: 28)
            x += 118
        }
        coverageLabel.frame = NSRect(x: max(x + 12, w - 340), y: 82, width: max(w - max(x + 12, w - 340) - 24, 120), height: 16)

        let bodyTop: CGFloat = 116
        let jobsHeight = max(150, min(230, h * 0.26))
        let bodyHeight = max(320, h - bodyTop - 16 - jobsHeight - 20)
        let filesWidth: CGFloat = 300
        filesCard.frame = NSRect(x: 24, y: bodyTop, width: filesWidth, height: bodyHeight)

        let wheelsX = 24 + filesWidth + 16
        let wheelsWidth = max(w - wheelsX - 24, 520)
        let gap: CGFloat = 16
        let cardWidth = (wheelsWidth - gap) / 2
        convertCard.frame = NSRect(x: wheelsX, y: bodyTop, width: cardWidth, height: bodyHeight)
        toolsCard.frame = NSRect(x: wheelsX + cardWidth + gap, y: bodyTop, width: cardWidth, height: bodyHeight)

        let jobsTop = bodyTop + bodyHeight + 16
        jobsCard.frame = NSRect(x: 24, y: jobsTop, width: w - 48, height: max(h - jobsTop - 20, 120))

        layoutFilesCard()
        layoutWheelCard(convertCard, wheel: convertWheel, title: convertTitle, caps: convertCaps, hint: convertHint)
        layoutWheelCard(toolsCard, wheel: toolsWheel, title: toolsTitle, caps: toolsCaps, hint: toolsHint)
        layoutJobsCard()
    }

    private func layoutFilesCard() {
        let bounds = filesCard.bounds
        filesHeader.frame = NSRect(x: 16, y: 12, width: 200, height: 18)
        dropZone.frame = NSRect(x: 16, y: 34, width: bounds.width - 32, height: 72)

        let applyTop = bounds.height - 46
        let statusTop = applyTop - 38
        let paramsTop = statusTop - 96
        let paramsHeaderTop = paramsTop - 22
        applyPill.frame = NSRect(x: 16, y: applyTop, width: bounds.width - 32, height: 30)
        statusLabel.frame = NSRect(x: 16, y: statusTop, width: bounds.width - 32, height: 32)
        paramsScroll.frame = NSRect(x: 16, y: paramsTop, width: bounds.width - 32, height: 88)
        paramsHeader.frame = NSRect(x: 16, y: paramsHeaderTop, width: 200, height: 18)

        let listTop: CGFloat = 114
        fileScroll.frame = NSRect(
            x: 12,
            y: listTop,
            width: bounds.width - 24,
            height: max(paramsHeaderTop - listTop - 12, 60)
        )
        fileList.frame = NSRect(x: 0, y: 0, width: fileScroll.bounds.width, height: fileScroll.bounds.height)
    }

    func wheelScale(for card: TangerineCard) -> CGFloat {
        let bounds = card.bounds
        let top: CGFloat = 62
        let availableWidth = bounds.width - 24
        let availableHeight = bounds.height - top - 30
        let side = min(availableWidth, availableHeight)
        let raw = (side - 28) / RadialMenuView.diameter
        return max(0.62, min(1.0, raw))
    }

    private func layoutWheelCard(
        _ card: TangerineCard,
        wheel: RadialMenuView,
        title: NSTextField,
        caps: TangerineKeycaps,
        hint: NSTextField
    ) {
        let bounds = card.bounds
        title.frame = NSRect(x: 16, y: 12, width: bounds.width - 32, height: 18)
        caps.frame = NSRect(x: 16, y: 34, width: min(caps.fittedWidth, bounds.width - 32), height: 18)
        hint.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width - 24, height: 16)

        let scale = wheelScale(for: card)
        let side = RadialMenuView.side(scale: scale)
        wheel.scale = scale
        let top: CGFloat = 62
        let room = bounds.height - top - 30
        wheel.frame = NSRect(
            x: (bounds.width - side) / 2,
            y: top + max((room - side) / 2, 0),
            width: side,
            height: side
        )
    }

    private func layoutJobsCard() {
        let bounds = jobsCard.bounds
        jobsHeader.frame = NSRect(x: 16, y: 12, width: 160, height: 18)
        clearPill.frame = NSRect(x: bounds.width - 120, y: 8, width: 104, height: 24)
        jobsScroll.frame = NSRect(x: 12, y: 36, width: bounds.width - 24, height: max(bounds.height - 48, 40))
        jobsList.frame = NSRect(x: 0, y: 0, width: jobsScroll.bounds.width, height: jobsScroll.bounds.height)
    }

    private func rewire(_ pill: TangerinePill, handler: @escaping () -> Void) {
        pill.action = handler
    }

    private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Usar"
        panel.message = "Escolha os arquivos para converter ou ajustar"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.setInputs(panel.urls)
        }
    }

    @discardableResult
    func moveInput(from index: Int, by delta: Int) -> Bool {
        let target = index + delta
        guard inputs.indices.contains(index), inputs.indices.contains(target) else { return false }
        inputs.swapAt(index, target)
        renderFiles()
        renderParams()
        return true
    }

    @discardableResult
    func removeInput(at index: Int) -> Bool {
        guard inputs.indices.contains(index) else { return false }
        inputs.remove(at: index)
        rebuildGroups()
        renderAll()
        return true
    }

    var orderedInputs: [URL] { inputs }

    private func setInputs(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        inputs = files
        if let detected = TangerineCategory.of(files[0]) {
            category = detected
        }
        rebuildGroups()
        renderAll()
        let mixed = Set(files.compactMap { TangerineCategory.of($0) }).count > 1
        if capability.isBarren {
            status(
                "Seleção incompatível: estes \(files.count) arquivos não têm nenhuma operação em comum.",
                warning: true
            )
        } else if mixed {
            status("Seleção mista: só o que serve a todos os \(files.count) arquivos.", warning: true)
        } else {
            status("\(files.count) arquivo(s) prontos.", warning: false)
        }
    }

    private var effectiveCategory: TangerineCategory {
        inputs.first.flatMap(TangerineCategory.of) ?? category
    }

    private func selectCategory(_ next: TangerineCategory) {
        category = next
        rebuildGroups()
        renderAll()
        if !inputs.isEmpty, effectiveCategory != next {
            status("As opções seguem \(inputs[0].lastPathComponent).", warning: true)
        }
    }

    func wheel(for mode: TangerineMode) -> RadialMenuView {
        mode == .convert ? convertWheel : toolsWheel
    }

    func card(for mode: TangerineMode) -> TangerineCard {
        mode == .convert ? convertCard : toolsCard
    }

    var activeMode: TangerineMode { mode }

    private var activeWheel: RadialMenuView { wheel(for: mode) }

    private func focus(_ next: TangerineMode) {
        defer { renderFiles() }
        if mode != next {
            mode = next
            let other = wheel(for: next == .convert ? .tools : .convert)
            other.selection = RadialMenuView.Selection(group: other.selection.group, option: nil)
        }
        syncCards()
        renderParams()
    }

    private func syncCards() {
        convertCard.active = mode == .convert
        toolsCard.active = mode == .tools
        convertWheel.dimmed = mode != .convert
        toolsWheel.dimmed = mode != .tools
    }

    @discardableResult
    private func selectOption(_ option: TangerineOption) -> Bool {
        for candidate in [mode, mode == .convert ? .tools : TangerineMode.convert] {
            let view = wheel(for: candidate)
            for (groupIndex, group) in view.groups.enumerated() {
                if let index = group.options.firstIndex(where: { $0.id == option.id }) {
                    mode = candidate
                    view.selection = RadialMenuView.Selection(group: groupIndex, option: index)
                    let other = wheel(for: candidate == .convert ? .tools : .convert)
                    other.selection = RadialMenuView.Selection(group: other.selection.group, option: nil)
                    syncCards()
                    renderParams()
                    return true
                }
            }
        }
        return false
    }

    func groups(for urls: [URL], mode: TangerineMode) -> [TangerineGroup] {
        guard let first = urls.first else { return [] }
        let category = TangerineCategory.of(first) ?? self.category
        return groups(category: category, sources: urls, mode: mode, capability: jobs.capability(for: urls))
    }

    private func groups(
        category: TangerineCategory,
        sources: [URL],
        mode: TangerineMode,
        capability: TangerineCapability
    ) -> [TangerineGroup] {
        let extensions = Set(sources.map { TangerineCatalog.normalize($0.pathExtension) })
        let sourceExtension = extensions.count == 1 ? (extensions.first ?? "") : ""
        switch mode {
        case .convert:
            return TangerineCatalog.convertGroups(
                category: category,
                sourceExtension: sourceExtension,
                capability: capability
            )
        case .tools:
            let batch = TangerineCatalog.batchGroups(
                category: category,
                inputCount: sources.count,
                capability: capability
            )
            return TangerineCatalog.toolGroups(category: category, capability: capability) + batch
        }
    }

    private func rebuildGroups() {
        capability = inputs.isEmpty ? .unknown : jobs.capability(for: inputs)
        for candidate in [TangerineMode.convert, .tools] {
            let view = wheel(for: candidate)
            let next = groups(category: effectiveCategory, sources: inputs, mode: candidate, capability: capability)
            view.groups = next
            view.selection = RadialMenuView.Selection(group: 0, option: nil)
            view.headline = ""
            if !next.isEmpty {
                view.footnote = ""
            } else if inputs.count > 1 {
                view.footnote = "nada em comum entre os arquivos"
            } else {
                view.footnote = "nada disponível para esta origem"
            }
        }
        syncCards()
    }

    private var selectionSummary: String {
        let families = Set(inputs.compactMap { TangerineCategory.of($0) })
        if families.count == 1, let only = families.first { return only.title.lowercased() }
        return "tipos mistos"
    }

    var coverageSummary: String {
        let conversions = convertWheel.groups.flatMap(\.options).count
        let toolOptions = toolsWheel.groups.flatMap(\.options)
        let combos = toolOptions.filter(\.isBatch).count
        let tools = toolOptions.count - combos
        if inputs.isEmpty {
            return "escolha arquivos para ver o que dá"
        }
        if conversions + tools + combos == 0 {
            return "nada disponível para esta seleção"
        }
        var parts = ["\(conversions) conversões", "\(tools) ferramentas"]
        if combos > 0 { parts.append("\(combos) combinações") }
        return parts.joined(separator: " · ") + " agora"
    }

    private func renderAll() {
        for (key, pill) in tabPills { pill.selected = key == effectiveCategory }
        coverageLabel.stringValue = coverageSummary
        syncCards()
        renderFiles()
        renderParams()
        renderJobs()
    }

    private func renderFiles() {
        fileList.subviews.forEach { $0.removeFromSuperview() }
        let rowHeight: CGFloat = 24
        let width = fileList.bounds.width
        var y: CGFloat = 4
        let ordered = activeWheel.currentOption?.isBatch == true
        if inputs.isEmpty {
            let empty = TangerineTheme.label("arraste arquivos aqui ou escolha acima", size: 11.5, weight: .regular, color: TangerineTheme.inkFaint)
            empty.frame = NSRect(x: 12, y: y, width: width - 24, height: 18)
            fileList.addSubview(empty)
            y += rowHeight
        } else if inputs.count > 1 {
            let summary = TangerineTheme.label(
                "\(inputs.count) arquivos · \(selectionSummary)",
                size: 12,
                weight: .semibold,
                color: TangerineTheme.ink
            )
            summary.frame = NSRect(x: 12, y: y, width: width - 24, height: 18)
            fileList.addSubview(summary)
            y += rowHeight
            if ordered {
                let note = TangerineTheme.label(
                    "a ordem abaixo é a ordem da combinação",
                    size: 10.5,
                    weight: .regular,
                    color: TangerineTheme.accent
                )
                note.frame = NSRect(x: 12, y: y, width: width - 24, height: 16)
                fileList.addSubview(note)
                y += 20
            }
        }
        let reorderable = inputs.count > 1
        for (index, url) in inputs.enumerated() {
            let prefix = reorderable ? "\(index + 1). " : "• "
            let row = TangerineTheme.label(prefix + url.lastPathComponent, size: 12, weight: .regular, color: TangerineTheme.inkSoft)
            row.toolTip = url.path
            row.lineBreakMode = .byTruncatingMiddle
            let controlsWidth: CGFloat = reorderable ? 92 : 24
            row.frame = NSRect(x: 12, y: y, width: max(width - 24 - controlsWidth, 60), height: 18)
            fileList.addSubview(row)
            if reorderable {
                let up = TangerinePill(frame: NSRect(x: width - 100, y: y - 2, width: 26, height: 22), title: "↑") { [weak self] in
                    self?.moveInput(from: index, by: -1)
                }
                up.enabledAction = index > 0
                fileList.addSubview(up)
                let down = TangerinePill(frame: NSRect(x: width - 72, y: y - 2, width: 26, height: 22), title: "↓") { [weak self] in
                    self?.moveInput(from: index, by: 1)
                }
                down.enabledAction = index < inputs.count - 1
                fileList.addSubview(down)
            }
            let drop = TangerinePill(frame: NSRect(x: width - 44, y: y - 2, width: 26, height: 22), title: "×") { [weak self] in
                self?.removeInput(at: index)
            }
            fileList.addSubview(drop)
            y += rowHeight + (reorderable ? 2 : 0)
        }
        if !inputs.isEmpty {
            let clear = TangerinePill(frame: NSRect(x: 12, y: y + 2, width: 92, height: 22), title: "Limpar") { [weak self] in
                self?.inputs = []
                self?.rebuildGroups()
                self?.renderAll()
                self?.status("", warning: false)
            }
            fileList.addSubview(clear)
            y += 30
        }
        fileList.frame = NSRect(x: 0, y: 0, width: width, height: max(y, fileScroll.bounds.height))
        fileScroll.documentView = fileList
    }

    private func renderParams() {
        paramsBox.subviews.forEach { $0.removeFromSuperview() }
        paramFields.removeAll()
        paramChoices.removeAll()
        paramSwatches.removeAll()
        let boxWidth = max(paramsScroll.bounds.width - 4, 120)
        func fill(_ text: String, color: NSColor, height: CGFloat = 18) {
            let label = TangerineTheme.label(text, size: 11.5, weight: .regular, color: color)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.frame = NSRect(x: 0, y: 4, width: boxWidth, height: height)
            paramsBox.addSubview(label)
            paramsBox.frame = NSRect(x: 0, y: 0, width: boxWidth, height: max(paramsScroll.bounds.height, height + 8))
        }
        guard let option = activeWheel.currentOption else {
            applyPill.enabledAction = false
            fill("escolha uma operação numa das rodas", color: TangerineTheme.inkFaint)
            return
        }
        let blocker = jobs.blocker(option: option, inputs: inputs)
        applyPill.enabledAction = blocker == nil
        guard blocker == nil else {
            fill(blocker ?? "", color: TangerineTheme.danger, height: 32)
            return
        }
        guard option.needsParams else {
            let note = option.isBatch
                ? "\(option.title): 1 trabalho para \(inputs.count) arquivos"
                : "\(option.title) não pede ajustes"
            fill(note, color: TangerineTheme.inkFaint)
            return
        }
        let columns = option.params.count > 2 ? 2 : 1
        let cellWidth = (boxWidth - CGFloat(columns - 1) * 10) / CGFloat(columns)
        var rows = 0
        for (index, param) in option.params.enumerated() {
            let column = index % columns
            let row = index / columns
            rows = row + 1
            let x = CGFloat(column) * (cellWidth + 10)
            let y = CGFloat(row) * 44
            let label = TangerineTheme.label("\(param.label) (\(param.hint))", size: 10, weight: .medium, color: TangerineTheme.inkFaint)
            label.frame = NSRect(x: x + 2, y: y, width: cellWidth - 4, height: 14)
            paramsBox.addSubview(label)
            let identifier = key(option, param)
            let current = paramValues[identifier] ?? param.fallback
            if case let .choice(choices) = param.kind {
                let popup = NSPopUpButton(frame: NSRect(x: x, y: y + 14, width: cellWidth, height: 24), pullsDown: false)
                popup.addItems(withTitles: choices.map(\.label))
                if let hit = choices.firstIndex(where: { $0.value == current || $0.label == current }) {
                    popup.selectItem(at: hit)
                }
                popup.target = self
                popup.action = #selector(choiceChanged(_:))
                popup.identifier = NSUserInterfaceItemIdentifier(identifier)
                paramsBox.addSubview(popup)
                paramChoices[identifier] = popup
                continue
            }
            var fieldWidth = cellWidth
            if case .color = param.kind {
                fieldWidth = cellWidth - 24
                let swatch = NSView(frame: NSRect(x: x + cellWidth - 20, y: y + 17, width: 18, height: 18))
                swatch.wantsLayer = true
                swatch.layer?.cornerRadius = 4
                swatch.layer?.borderWidth = 1
                swatch.layer?.borderColor = NSColor(white: 0.78, alpha: 1).cgColor
                swatch.layer?.backgroundColor = TangerineDashboard.color(from: current)?.cgColor
                paramsBox.addSubview(swatch)
                paramSwatches[identifier] = swatch
            }
            let field = NSTextField(frame: NSRect(x: x, y: y + 16, width: fieldWidth, height: 22))
            field.stringValue = current
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(paramChanged(_:))
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            paramsBox.addSubview(field)
            paramFields[identifier] = field
        }
        paramsBox.frame = NSRect(
            x: 0,
            y: 0,
            width: boxWidth,
            height: max(CGFloat(rows) * 44 + 6, paramsScroll.bounds.height)
        )
        paramsScroll.documentView = paramsBox
    }

    static func color(from raw: String) -> NSColor? {
        let probe = TangerineParam(id: "p", label: "Fundo", kind: .color, fallback: "#ffffff", hint: "")
        guard case let .value(value) = probe.parse(raw), let text = value.string else { return nil }
        if text == "transparent" { return NSColor(white: 0.5, alpha: 0.15) }
        let digits = Array(text.dropFirst())
        func component(_ range: Range<Int>) -> CGFloat {
            CGFloat(Int(String(digits[range]), radix: 16) ?? 0) / 255
        }
        return NSColor(
            calibratedRed: component(0..<2),
            green: component(2..<4),
            blue: component(4..<6),
            alpha: 1
        )
    }

    @objc private func paramChanged(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        paramValues[id] = sender.stringValue
        if let swatch = paramSwatches[id] {
            swatch.layer?.backgroundColor = TangerineDashboard.color(from: sender.stringValue)?.cgColor
        }
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let title = sender.titleOfSelectedItem else { return }
        paramValues[id] = title
    }

    private func key(_ option: TangerineOption, _ param: TangerineParam) -> String {
        "\(option.id).\(param.id)"
    }

    private func renderJobs() {
        jobsList.subviews.forEach { $0.removeFromSuperview() }
        let width = jobsList.bounds.width
        let rowHeight: CGFloat = 44
        var y: CGFloat = 0
        if jobs.jobs.isEmpty {
            let empty = TangerineTheme.label("nenhum trabalho ainda", size: 11.5, weight: .regular, color: TangerineTheme.inkFaint)
            empty.frame = NSRect(x: 8, y: 6, width: width - 16, height: 18)
            jobsList.addSubview(empty)
            y = 30
        }
        for job in jobs.jobs {
            let row = FlippedContainer(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            let dot = NSView(frame: NSRect(x: 6, y: 16, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            switch job.state {
            case .running: dot.layer?.backgroundColor = TangerineTheme.accent.cgColor
            case .done: dot.layer?.backgroundColor = TangerineTheme.ok.cgColor
            case .failed: dot.layer?.backgroundColor = TangerineTheme.danger.cgColor
            case .cancelled: dot.layer?.backgroundColor = TangerineTheme.inkFaint.cgColor
            }
            row.addSubview(dot)

            let title = TangerineTheme.label(job.title, size: 12.5, weight: .semibold)
            title.toolTip = job.input.path
            title.frame = NSRect(x: 26, y: 6, width: width - 210, height: 17)
            row.addSubview(title)

            let color: NSColor = job.state == .failed ? TangerineTheme.danger : TangerineTheme.inkSoft
            let subtitle = TangerineTheme.label(job.subtitle, size: 11, weight: .regular, color: color)
            subtitle.toolTip = job.subtitle
            subtitle.frame = NSRect(x: 26, y: 23, width: width - 210, height: 15)
            row.addSubview(subtitle)

            if job.state == .running {
                let spinner = NSProgressIndicator(frame: NSRect(x: width - 214, y: 14, width: 16, height: 16))
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isIndeterminate = true
                spinner.startAnimation(nil)
                row.addSubview(spinner)
                let cancel = TangerinePill(frame: NSRect(x: width - 186, y: 10, width: 84, height: 24), title: "Cancelar") { [weak self] in
                    self?.jobs.cancel(job)
                }
                row.addSubview(cancel)
            } else if job.state == .done, !job.outputs.isEmpty {
                let reveal = TangerinePill(frame: NSRect(x: width - 186, y: 10, width: 84, height: 24), title: "Mostrar") {
                    NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
                }
                row.addSubview(reveal)
                let open = TangerinePill(frame: NSRect(x: width - 96, y: 10, width: 84, height: 24), title: "Abrir") {
                    if let first = job.outputs.first { NSWorkspace.shared.open(first) }
                }
                row.addSubview(open)
            } else if job.state == .failed {
                let retry = TangerinePill(frame: NSRect(x: width - 96, y: 10, width: 84, height: 24), title: "Repetir") { [weak self] in
                    self?.jobs.submit(inputs: job.inputs, option: job.option, values: job.values)
                }
                row.addSubview(retry)
            }

            jobsList.addSubview(row)
            y += rowHeight
        }
        jobsList.frame = NSRect(x: 0, y: 0, width: width, height: max(y, jobsScroll.bounds.height))
        jobsScroll.documentView = jobsList
        if jobs.hasRunning { startTicker() }
    }

    private func status(_ text: String, warning: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = warning ? TangerineTheme.danger : TangerineTheme.inkSoft
    }

    @discardableResult
    func runSelection() -> Bool {
        guard !inputs.isEmpty else {
            status("Escolha ao menos um arquivo.", warning: true)
            return false
        }
        guard let option = activeWheel.currentOption else {
            status("Escolha uma operação numa das rodas.", warning: true)
            return false
        }
        if let blocker = jobs.blocker(option: option, inputs: inputs) {
            status("\(blocker) Nada foi enviado.", warning: true)
            return false
        }
        var values: [String: TangerineValue] = [:]
        for param in option.params {
            let raw = paramFields[key(option, param)]?.stringValue
                ?? paramValues[key(option, param)]
                ?? param.fallback
            paramValues[key(option, param)] = raw
            switch param.parse(raw) {
            case let .value(value):
                values[param.id] = value
            case let .problem(reason):
                status(reason, warning: true)
                return false
            }
        }
        if let problem = TangerineCatalog.batchProblem(option: option, values: values, inputCount: inputs.count) {
            status(problem, warning: true)
            return false
        }
        jobs.submit(inputs: inputs, option: option, values: values)
        if option.isBatch {
            status("\(option.title): 1 trabalho com \(inputs.count) arquivos na ordem da lista.", warning: false)
        } else {
            status("\(option.title): \(inputs.count) trabalho(s) enviados.", warning: false)
        }
        startTicker()
        return true
    }

    @discardableResult
    func run(inputs: [URL], option: TangerineOption) -> Bool {
        setInputs(inputs)
        guard selectOption(option) else {
            status("\(option.title) não serve a todos os arquivos escolhidos.", warning: true)
            return false
        }
        return runSelection()
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: activeWheel.moveOption(-1)
        case 124: activeWheel.moveOption(1)
        case 125: activeWheel.moveGroup(1)
        case 126: activeWheel.moveGroup(-1)
        case 36, 76:
            if activeWheel.currentOption == nil {
                runSelection()
            } else {
                activeWheel.commit()
            }
        case 53:
            close()
        case 48:
            focus(mode == .convert ? .tools : .convert)
            if activeWheel.currentOption == nil { activeWheel.moveOption(1) }
        default:
            return false
        }
        renderParams()
        return true
    }

    var rootView: NSView { root }

    func resizeForTests(width: CGFloat, height: CGFloat) {
        root.setFrameSize(NSSize(width: width, height: height))
        layoutChrome()
    }

    func wheelFrameInRoot(for mode: TangerineMode) -> NSRect {
        let card = card(for: mode)
        return root.convert(wheel(for: mode).frame, from: card)
    }

    private func startTicker() {
        guard ticker == nil, window.isVisible else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.jobs.hasRunning else {
                self.stopTicker()
                self.renderJobs()
                return
            }
            self.renderJobs()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopTicker()
    }
}

final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

final class DashboardRootView: NSView {
    override var isFlipped: Bool { true }
    weak var dashboard: TangerineDashboard?
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        dashboard?.layoutChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func keyDown(with event: NSEvent) {
        if dashboard?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

final class DashboardDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var hot = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL] ?? []).filter { $0.isFileURL }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hot = !urls(sender).isEmpty
        needsDisplay = true
        return hot ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hot = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        hot = false
        needsDisplay = true
        guard !files.isEmpty else { return false }
        onDrop?(files)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        (hot ? TangerineTheme.accentSoft : NSColor(white: 0.97, alpha: 1)).setFill()
        path.fill()
        (hot ? TangerineTheme.accent : NSColor(white: 0.80, alpha: 1)).setStroke()
        path.lineWidth = hot ? 2 : 1
        let dashes: [CGFloat] = [5, 4]
        path.setLineDash(dashes, count: 2, phase: 0)
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "solte arquivos aqui"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: hot ? TangerineTheme.accent : TangerineTheme.inkFaint,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(
            in: NSRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18),
            withAttributes: attributes
        )
    }
}
