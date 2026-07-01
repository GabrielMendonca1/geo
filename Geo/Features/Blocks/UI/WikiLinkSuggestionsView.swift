import AppKit
import SwiftUI

struct WikiLinkSuggestionItem: Identifiable, Hashable {
    let id: String
    let title: String
}

struct WikiLinkSuggestionsView: View {
    let items: [WikiLinkSuggestionItem]
    let selectedIndex: Int
    let onSelect: (WikiLinkSuggestionItem) -> Void
    let onHover: (Int) -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item: item, isSelected: index == selectedIndex)
                    .onHover { hovering in
                        if hovering { onHover(index) }
                    }
                    .onTapGesture { onSelect(item) }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.border.opacity(0.4), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        )
        .frame(width: 260)
    }

    private func row(item: WikiLinkSuggestionItem, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Palette.accent : Palette.tertiaryForeground)
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.system(size: 13))
                .foregroundColor(Palette.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Palette.accent.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

@MainActor
final class WikiLinkAutocompleteController: NSObject {
    static let shared = WikiLinkAutocompleteController()

    private var panel: NSPanel?
    private weak var hostTextView: NSTextView?
    private var allTitles: [WikiLinkSuggestionItem] = []
    private var filtered: [WikiLinkSuggestionItem] = []
    private var selectedIndex: Int = 0
    private var triggerLocation: Int?
    private var keyMonitor: Any?
    private var textChangeObserver: Any?
    private var selectionObserver: Any?
    private var resignObserver: Any?
    private var windowResignObserver: Any?
    private var hostingView: NSHostingView<AnyView>?

    private static let maxResults = 10

    func attach(to textView: NSTextView, titles: [WikiLinkSuggestionItem]) {
        if hostTextView !== textView {
            detach()
            hostTextView = textView
            textChangeObserver = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleTextChange() }
            }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSelectionChange() }
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: textView.window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
        allTitles = titles
    }

    func updateTitles(_ titles: [WikiLinkSuggestionItem]) {
        allTitles = titles
        if isVisible { recompute() }
    }

    func detach() {
        dismiss()
        if let textChangeObserver { NotificationCenter.default.removeObserver(textChangeObserver) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        textChangeObserver = nil
        selectionObserver = nil
        resignObserver = nil
        hostTextView = nil
        allTitles = []
    }

    private var isVisible: Bool { panel?.isVisible == true }

    private func handleTextChange() {
        guard let textView = hostTextView else { return }
        let nsString = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret <= nsString.length else { dismiss(); return }

        if let trigger = locateTriggerStart(in: nsString, before: caret) {
            triggerLocation = trigger
            recompute()
            present()
        } else {
            dismiss()
        }
    }

    private func handleSelectionChange() {
        guard isVisible else { return }
        guard let textView = hostTextView, let trigger = triggerLocation else { return }
        let caret = textView.selectedRange().location
        let nsString = textView.string as NSString
        if caret < trigger + 2 || caret > nsString.length {
            dismiss()
            return
        }
        let queryRange = NSRange(location: trigger + 2, length: caret - (trigger + 2))
        let query = nsString.substring(with: queryRange)
        if query.contains("\n") || query.contains("]") {
            dismiss()
            return
        }
        recompute()
    }

    private func locateTriggerStart(in nsString: NSString, before caret: Int) -> Int? {
        var i = caret - 1
        while i >= 1 {
            let ch = nsString.character(at: i)
            let prev = nsString.character(at: i - 1)
            let scalar = UnicodeScalar(ch)
            if ch == 0x5D { return nil }
            if scalar.map({ CharacterSet.newlines.contains($0) }) == true { return nil }
            if prev == 0x5B && ch == 0x5B {
                return i - 1
            }
            i -= 1
        }
        return nil
    }

    private func currentQuery() -> String {
        guard let textView = hostTextView, let trigger = triggerLocation else { return "" }
        let nsString = textView.string as NSString
        let caret = textView.selectedRange().location
        let start = trigger + 2
        guard caret >= start, caret <= nsString.length else { return "" }
        return nsString.substring(with: NSRange(location: start, length: caret - start))
    }

    private func recompute() {
        let query = currentQuery().lowercased()
        let matches: [WikiLinkSuggestionItem]
        if query.isEmpty {
            matches = Array(allTitles.prefix(Self.maxResults))
        } else {
            matches = allTitles
                .filter { $0.title.lowercased().contains(query) }
                .prefix(Self.maxResults)
                .map { $0 }
        }
        filtered = matches
        if selectedIndex >= filtered.count { selectedIndex = max(0, filtered.count - 1) }
        if filtered.isEmpty {
            dismiss()
        } else {
            renderContent()
        }
    }

    private func present() {
        guard !filtered.isEmpty, let textView = hostTextView, let window = textView.window else { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.hasShadow = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = true
            panel = p
        }

        renderContent()
        positionPanel(relativeTo: textView, in: window)
        if panel?.isVisible == false {
            window.addChildWindow(panel!, ordered: .above)
        }
        installKeyMonitorIfNeeded()
        if windowResignObserver == nil {
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
    }

    private func renderContent() {
        guard let panel else { return }
        let view = WikiLinkSuggestionsView(
            items: filtered,
            selectedIndex: selectedIndex,
            onSelect: { [weak self] item in
                Task { @MainActor in self?.commit(item: item) }
            },
            onHover: { [weak self] index in
                Task { @MainActor in self?.setSelectedIndex(index) }
            }
        )
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(260, fitting.width), height: max(40, fitting.height))
        panel.setContentSize(size)
        hostingView = hosting
        if let textView = hostTextView, let window = textView.window {
            positionPanel(relativeTo: textView, in: window)
        }
    }

    private func positionPanel(relativeTo textView: NSTextView, in window: NSWindow) {
        guard let panel else { return }
        let caret = textView.selectedRange().location
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, caret - 1))
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let viewPoint = NSPoint(x: rect.minX, y: rect.maxY)
        let windowRect = textView.convert(NSRect(origin: viewPoint, size: .zero), to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let panelHeight = panel.frame.height
        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - panelHeight - 4)
        if let screenFrame = window.screen?.visibleFrame {
            if origin.y < screenFrame.minY {
                origin.y = screenRect.minY + rect.height + 4
            }
            if origin.x + panel.frame.width > screenFrame.maxX {
                origin.x = screenFrame.maxX - panel.frame.width - 8
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, !filtered.isEmpty else { return event }
        switch event.keyCode {
        case 125:
            setSelectedIndex(min(selectedIndex + 1, filtered.count - 1))
            return nil
        case 126:
            setSelectedIndex(max(selectedIndex - 1, 0))
            return nil
        case 36, 76:
            if selectedIndex < filtered.count {
                commit(item: filtered[selectedIndex])
            }
            return nil
        case 53:
            dismiss()
            return nil
        case 48:
            if selectedIndex < filtered.count {
                commit(item: filtered[selectedIndex])
            }
            return nil
        default:
            return event
        }
    }

    private func setSelectedIndex(_ index: Int) {
        guard index != selectedIndex, index >= 0, index < filtered.count else { return }
        selectedIndex = index
        renderContent()
    }

    private func commit(item: WikiLinkSuggestionItem) {
        guard let textView = hostTextView, let trigger = triggerLocation else { dismiss(); return }
        let nsString = textView.string as NSString
        let caret = textView.selectedRange().location
        let replaceRange = NSRange(location: trigger, length: max(0, caret - trigger))
        let replacement = "[[" + item.title + "]]"
        if textView.shouldChangeText(in: replaceRange, replacementString: replacement) {
            textView.replaceCharacters(in: replaceRange, with: replacement)
            textView.didChangeText()
            let cursor = trigger + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
        }
        dismiss()
    }

    private func dismiss() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
        windowResignObserver = nil
        triggerLocation = nil
        selectedIndex = 0
        filtered = []
    }
}

struct WikiLinkAutocompleteAttachment: NSViewRepresentable {
    let titles: [WikiLinkSuggestionItem]

    func makeNSView(context: Context) -> NSView {
        let view = AttachmentProbeView()
        view.onMove = { window in
            context.coordinator.bindIfNeeded(in: window, titles: titles)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateTitles(titles)
        if let probe = nsView as? AttachmentProbeView, let window = probe.window {
            context.coordinator.bindIfNeeded(in: window, titles: titles)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private weak var boundTextView: NSTextView?
        private var pollTask: Task<Void, Never>?

        private static let maxPollIterations = 40
        private static let pollIntervalNanoseconds: UInt64 = 150_000_000

        func bindIfNeeded(in window: NSWindow, titles: [WikiLinkSuggestionItem]) {
            if let existing = boundTextView, existing.window === window {
                WikiLinkAutocompleteController.shared.updateTitles(titles)
                return
            }
            pollTask?.cancel()
            pollTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<Self.maxPollIterations {
                    if Task.isCancelled { return }
                    if let tv = Self.findTextView(in: window) {
                        WikiLinkAutocompleteController.shared.attach(to: tv, titles: titles)
                        self.boundTextView = tv
                        return
                    }
                    try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                }
            }
        }

        func updateTitles(_ titles: [WikiLinkSuggestionItem]) {
            WikiLinkAutocompleteController.shared.updateTitles(titles)
        }

        func tearDown() {
            pollTask?.cancel()
            pollTask = nil
            WikiLinkAutocompleteController.shared.detach()
            boundTextView = nil
        }

        static func findTextView(in window: NSWindow) -> NSTextView? {
            guard let root = window.contentView else { return nil }
            return Self.firstTextView(in: root)
        }

        static func firstTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, tv.isEditable { return tv }
            for sub in view.subviews {
                if let tv = firstTextView(in: sub) { return tv }
            }
            return nil
        }
    }
}

private final class AttachmentProbeView: NSView {
    var onMove: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onMove?(window) }
    }
}
