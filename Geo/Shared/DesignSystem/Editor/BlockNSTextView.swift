import AppKit

private final class EditorBlockKindWrapper: NSObject {
    let kind: EditorBlockKind
    init(_ kind: EditorBlockKind) { self.kind = kind }
}

final class BlockNSTextView: NSTextView {
    var onEvent: ((BlockEditorEvent) -> Void)?
    var onWillEmitContent: ((String) -> Void)?
    var isSlashMode = false
    var isMentionMode = false
    var allowsInternalNewlines = false
    var canMerge = true
    var hasMultiBlockSelection = false
    var pasteHandler: ((NSPasteboard, NSTextView) -> Bool)?
    var baseFont: NSFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var baseForeground: NSColor = .labelColor
    var lineHeightMultiple: CGFloat = 1.3
    private var isAutoFormatting = false
    private var didRegisterDragTypes = false
    var blockId: UUID?
    var blockKind: EditorBlockKind = .paragraph
    weak var focusCoordinator: EditorFocusCoordinator?
    var onDragOutside: ((NSPoint) -> Void)?
    var isApplyingTransaction: Bool = false

    private let keyHandler = TextViewKeyHandler()
    private let autoFormat = AutoFormatEngine()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let fullRange = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.geoLink, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let adjustedRect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(adjustedRect, cursor: .pointingHand)
        }
        ts.enumerateAttribute(.geoWikiLink, in: fullRange) { value, range, _ in
            guard let isWiki = value as? Bool, isWiki else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let adjustedRect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(adjustedRect, cursor: .pointingHand)
        }
    }

    var activeFormatting = ActiveFormattingState()
    var onFormattingStateChange: ((ActiveFormattingState) -> Void)?

    private(set) var toolbarPanel: FloatingToolbarPanel?
    private var toolbarDismissTimer: DispatchWorkItem?
    private var scrollObserver: NSObjectProtocol?
    private var lastMeasuredWidth: CGFloat = -1

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        toolbarPanel?.dismiss()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !didRegisterDragTypes {
            registerForDraggedTypes([.fileURL])
            didRegisterDragTypes = true
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.toolbarDismissTimer?.cancel()
            self?.toolbarPanel?.dismiss()
        }
    }

    override var intrinsicContentSize: NSSize {
        TextViewHeightCalculator.calculateHeight(for: self)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - lastMeasuredWidth) > 0.5 else { return }
        lastMeasuredWidth = width
        DispatchQueue.main.async { [weak self] in
            self?.invalidateIntrinsicContentSize()
        }
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeightMultiple
        return [
            .font: baseFont,
            .foregroundColor: baseForeground,
            .paragraphStyle: para
        ]
    }

    func applySyntaxHighlighting() {
        guard case .codeBlock(let language) = blockKind else { return }
        guard let ts = textStorage, ts.length > 0 else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tokens = SyntaxHighlighter.highlight(code: ts.string, language: language)
        let fullRange = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        ts.addAttribute(.foregroundColor, value: baseForeground, range: fullRange)
        for token in tokens {
            let safe = NSIntersectionRange(token.range, fullRange)
            guard safe.length > 0 else { continue }
            ts.addAttribute(.foregroundColor, value: SyntaxHighlighter.colorForToken(token.type, isDark: isDark), range: safe)
        }
        ts.endEditing()
    }

    func setAutoFormatting(_ value: Bool) {
        isAutoFormatting = value
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isApplyingTransaction { return true }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isAutoFormatting else { return }
        invalidateIntrinsicContentSize()
        guard !hasMarkedText() else { return }
        flushContentChange()
    }

    private func flushContentChange() {
        guard let ts = textStorage else { return }
        autoFormat.checkAndApply(in: self)
        if case .codeBlock = blockKind {
            applySyntaxHighlighting()
        }
        let spans = SpanExtractor.extract(from: ts, baseFont: baseFont)
        let snapshot = string
        onWillEmitContent?(snapshot)
        onEvent?(.contentChange(snapshot, spans))
        updateSlashAndMentionState()
    }

    private func updateSlashAndMentionState() {
        let caretAt = selectedRange().location
        let text = string
        let startsWithSlash = text.hasPrefix("/")
        let inSlashRegion = startsWithSlash && caretAt >= 1

        if inSlashRegion && !isSlashMode {
            isSlashMode = true
        } else if isSlashMode && !inSlashRegion {
            isSlashMode = false
        }

        let mentionCursor = selectedRange().location
        let beforeCursor = (text as NSString).substring(to: mentionCursor)
        if let openRange = beforeCursor.range(of: "[[", options: .backwards) {
            let afterOpen = beforeCursor[openRange.upperBound...]
            isMentionMode = !afterOpen.contains("]]")
        } else {
            isMentionMode = false
        }
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        if isDragSelecting {
            super.setSelectedRange(NSRange(location: 0, length: 0), affinity: affinity, stillSelecting: stillSelectingFlag)
            return
        }
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if isSlashMode && (charRange.location == 0 || !string.hasPrefix("/")) {
            isSlashMode = false
            onEvent?(.slashDismissed)
        }
        updateFormattingState(at: charRange)

        if charRange.length > 0 && !stillSelectingFlag {
            showToolbar(for: charRange)
        } else if charRange.length == 0 {
            scheduleToolbarDismiss()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            var charIndex = characterIndexForInsertion(at: point)
            if let ts = textStorage, ts.length > 0 {
                if charIndex >= ts.length { charIndex = ts.length - 1 }
                if charIndex >= 0 {
                    if let isWiki = ts.attribute(.geoWikiLink, at: charIndex, effectiveRange: nil) as? Bool, isWiki {
                        var effectiveRange = NSRange()
                        ts.attribute(.geoWikiLink, at: charIndex, longestEffectiveRange: &effectiveRange, in: NSRange(location: 0, length: ts.length))
                        let displayed = (ts.string as NSString).substring(with: effectiveRange)
                        let target = (ts.attribute(.geoWikiTarget, at: charIndex, effectiveRange: nil) as? String) ?? displayed
                        let anchor = ts.attribute(.geoWikiAnchor, at: charIndex, effectiveRange: nil) as? String
                        let isEmbed = (ts.attribute(.geoEmbed, at: charIndex, effectiveRange: nil) as? Bool) == true
                        onEvent?(.wikiLinkClicked(WikiLinkClickPayload(target: target, anchor: anchor, isEmbed: isEmbed)))
                        return
                    }
                    if let urlString = ts.attribute(.geoLink, at: charIndex, effectiveRange: nil) as? String,
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                        return
                    }
                }
            }
        }
        isDragSelecting = false
        let dragTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self, let window = self.window else { t.invalidate(); return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else { t.invalidate(); return }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = self.convert(mouseInWindow, from: nil)
            let outside = mouseInView.y < -10 || mouseInView.y > self.bounds.height + 10
            if outside {
                if !self.isDragSelecting {
                    self.isDragSelecting = true
                }
                self.onDragOutside?(mouseInWindow)
            }
        }
        RunLoop.current.add(dragTimer, forMode: .eventTracking)
        super.mouseDown(with: event)
        dragTimer.invalidate()
        let wasBlockDrag = isDragSelecting
        isDragSelecting = false
        if wasBlockDrag {
            window?.makeFirstResponder(nil)
        }
    }

    private func updateFormattingState(at range: NSRange) {
        guard range.length > 0 else {
            if activeFormatting.isBold || activeFormatting.isItalic || activeFormatting.isStrikethrough || activeFormatting.isCode || activeFormatting.isHighlight {
                activeFormatting = ActiveFormattingState()
                onFormattingStateChange?(activeFormatting)
            }
            return
        }
        guard let ts = textStorage, ts.length > 0 else { return }
        let checkPos = max(0, min(range.location, ts.length - 1))
        guard checkPos < ts.length else { return }

        var state = ActiveFormattingState()

        if let font = ts.attribute(.font, at: checkPos, effectiveRange: nil) as? NSFont {
            let boldFont = SpanStyler.boldFont(for: baseFont)
            let ctFont = font as CTFont
            let matrix = CTFontGetMatrix(ctFont)
            let isOblique = matrix.c != 0

            if font.fontName == boldFont.fontName {
                state.isBold = true
                if isOblique { state.isItalic = true }
            } else if isOblique {
                state.isItalic = true
            }

            let codeFont = EditorFontCache.shared.font(for: baseFont, style: .code)
            if font.fontName == codeFont.fontName && font.pointSize == codeFont.pointSize {
                state.isCode = true
            }
        }

        if let strike = ts.attribute(.strikethroughStyle, at: checkPos, effectiveRange: nil) as? Int,
           strike != 0 {
            state.isStrikethrough = true
        }

        if let isHighlight = ts.attribute(.geoHighlight, at: checkPos, effectiveRange: nil) as? Bool, isHighlight {
            state.isHighlight = true
        }

        activeFormatting = state
        onFormattingStateChange?(state)
    }

    private func showToolbar(for range: NSRange) {
        toolbarDismissTimer?.cancel()
        guard let lm = layoutManager, let tc = textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let containerRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let origin = textContainerOrigin
        let selRect = containerRect.offsetBy(dx: origin.x, dy: origin.y)

        if toolbarPanel == nil {
            let tp = FloatingToolbarPanel()
            tp.onBold = { [weak self] in
                self?.toggleInlineFormat(style: .bold)
                self?.updateActiveFormattingAndToolbar()
            }
            tp.onItalic = { [weak self] in
                self?.toggleInlineFormat(style: .italic)
                self?.updateActiveFormattingAndToolbar()
            }
            tp.onStrikethrough = { [weak self] in
                self?.toggleInlineFormat(style: .strikethrough)
                self?.updateActiveFormattingAndToolbar()
            }
            tp.onCode = { [weak self] in
                self?.toggleInlineFormat(style: .code)
                self?.updateActiveFormattingAndToolbar()
            }
            tp.onHighlight = { [weak self] in
                self?.toggleInlineFormat(style: .highlight)
                self?.updateActiveFormattingAndToolbar()
            }
            tp.onLink = { [weak self] in self?.insertLink() }
            tp.onTurnInto = { [weak self] kind in self?.onEvent?(.convertTo(kind)) }
            toolbarPanel = tp
        }
        toolbarPanel?.show(above: selRect, in: self, formatting: activeFormatting)
    }

    private func scheduleToolbarDismiss() {
        toolbarDismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.toolbarPanel?.dismiss()
        }
        toolbarDismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func updateActiveFormattingAndToolbar() {
        updateFormattingState(at: selectedRange())
        toolbarPanel?.updateFormatting(activeFormatting)
    }

    func insertLink() {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let selectedText = (string as NSString).substring(with: sel)
        let linkMarkdown = "[\(selectedText)](url)"
        insertText(linkMarkdown, replacementRange: sel)
        let urlStart = sel.location + selectedText.count + 3
        setSelectedRange(NSRange(location: urlStart, length: 3))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let sel = selectedRange()
        var insertIndex = 0

        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
        }

        if sel.length > 0 {
            let boldItem = NSMenuItem(title: "Bold", action: #selector(menuToggleBold), keyEquivalent: "b")
            boldItem.keyEquivalentModifierMask = .command
            boldItem.state = activeFormatting.isBold ? .on : .off
            insert(boldItem)

            let italicItem = NSMenuItem(title: "Italic", action: #selector(menuToggleItalic), keyEquivalent: "i")
            italicItem.keyEquivalentModifierMask = .command
            italicItem.state = activeFormatting.isItalic ? .on : .off
            insert(italicItem)

            let strikeItem = NSMenuItem(title: "Strikethrough", action: #selector(menuToggleStrikethrough), keyEquivalent: "s")
            strikeItem.keyEquivalentModifierMask = [.command, .shift]
            strikeItem.state = activeFormatting.isStrikethrough ? .on : .off
            insert(strikeItem)

            let codeItem = NSMenuItem(title: "Code", action: #selector(menuToggleCode), keyEquivalent: "e")
            codeItem.keyEquivalentModifierMask = .command
            codeItem.state = activeFormatting.isCode ? .on : .off
            insert(codeItem)

            let highlightItem = NSMenuItem(title: "Highlight", action: #selector(menuToggleHighlight), keyEquivalent: "h")
            highlightItem.keyEquivalentModifierMask = [.command, .shift]
            highlightItem.state = activeFormatting.isHighlight ? .on : .off
            insert(highlightItem)

            insert(.separator())

            insert(NSMenuItem(title: "Link", action: #selector(menuInsertLink), keyEquivalent: ""))

            insert(.separator())
        } else {
            let turnIntoMenu = NSMenu()

            let paraItem = NSMenuItem(title: "Paragraph", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            paraItem.representedObject = EditorBlockKindWrapper(.paragraph)
            turnIntoMenu.addItem(paraItem)

            turnIntoMenu.addItem(.separator())

            let h1Item = NSMenuItem(title: "Heading 1", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            h1Item.representedObject = EditorBlockKindWrapper(.heading(level: 1))
            turnIntoMenu.addItem(h1Item)

            let h2Item = NSMenuItem(title: "Heading 2", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            h2Item.representedObject = EditorBlockKindWrapper(.heading(level: 2))
            turnIntoMenu.addItem(h2Item)

            let h3Item = NSMenuItem(title: "Heading 3", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            h3Item.representedObject = EditorBlockKindWrapper(.heading(level: 3))
            turnIntoMenu.addItem(h3Item)

            turnIntoMenu.addItem(.separator())

            let bulletItem = NSMenuItem(title: "Bullet List", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            bulletItem.representedObject = EditorBlockKindWrapper(.bulletItem(marker: "-"))
            turnIntoMenu.addItem(bulletItem)

            let numberedItem = NSMenuItem(title: "Numbered List", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            numberedItem.representedObject = EditorBlockKindWrapper(.orderedItem(number: 1))
            turnIntoMenu.addItem(numberedItem)

            let todoItem = NSMenuItem(title: "To-do", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            todoItem.representedObject = EditorBlockKindWrapper(.checkboxItem(checked: false, marker: "-"))
            turnIntoMenu.addItem(todoItem)

            turnIntoMenu.addItem(.separator())

            let quoteItem = NSMenuItem(title: "Quote", action: #selector(menuTurnInto(_:)), keyEquivalent: "")
            quoteItem.representedObject = EditorBlockKindWrapper(.blockquote)
            turnIntoMenu.addItem(quoteItem)

            let turnIntoItem = NSMenuItem(title: "Turn Into", action: nil, keyEquivalent: "")
            turnIntoItem.submenu = turnIntoMenu
            insert(turnIntoItem)

            insert(.separator())

            let dupItem = NSMenuItem(title: "Duplicate", action: #selector(menuDuplicate), keyEquivalent: "d")
            dupItem.keyEquivalentModifierMask = .command
            insert(dupItem)

            insert(NSMenuItem(title: "Delete", action: #selector(menuDelete), keyEquivalent: ""))

            insert(.separator())
        }

        return menu
    }

    @objc private func menuToggleBold() {
        toggleInlineFormat(style: .bold)
        updateActiveFormattingAndToolbar()
    }

    @objc private func menuToggleItalic() {
        toggleInlineFormat(style: .italic)
        updateActiveFormattingAndToolbar()
    }

    @objc private func menuToggleStrikethrough() {
        toggleInlineFormat(style: .strikethrough)
        updateActiveFormattingAndToolbar()
    }

    @objc private func menuToggleCode() {
        toggleInlineFormat(style: .code)
        updateActiveFormattingAndToolbar()
    }

    @objc private func menuToggleHighlight() {
        toggleInlineFormat(style: .highlight)
        updateActiveFormattingAndToolbar()
    }

    @objc private func menuInsertLink() {
        insertLink()
    }

    @objc private func menuDuplicate() {
        onEvent?(.duplicate)
    }

    @objc private func menuDelete() {
        onEvent?(.delete)
    }

    @objc private func menuTurnInto(_ sender: NSMenuItem) {
        guard let wrapper = sender.representedObject as? EditorBlockKindWrapper else { return }
        onEvent?(.convertTo(wrapper.kind))
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            if let blockId { focusCoordinator?.notifyFocusGained(blockId: blockId) }
            onEvent?(.focus)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        if let blockId { focusCoordinator?.notifyFocusLost(blockId: blockId) }
        let result = super.resignFirstResponder()
        if result {
            toolbarDismissTimer?.cancel()
            toolbarPanel?.dismiss()
        }
        return result
    }

    override func paste(_ sender: Any?) {
        if let handler = pasteHandler, handler(NSPasteboard.general, self) {
            return
        }
        if let htmlData = NSPasteboard.general.data(forType: .html),
           let htmlString = String(data: htmlData, encoding: .utf8),
           let markdown = HTMLToMarkdown.convert(htmlString) {
            if allowsInternalNewlines {
                insertText(markdown, replacementRange: selectedRange())
                return
            }
            var rawLines = markdown.components(separatedBy: .newlines)
            while rawLines.last?.isEmpty == true && rawLines.count > 1 {
                rawLines.removeLast()
            }
            if rawLines.count <= 1 {
                insertText(rawLines.first ?? "", replacementRange: selectedRange())
                return
            }
            let sel = selectedRange()
            let ns = string as NSString
            let before = ns.substring(to: sel.location)
            let after = ns.substring(from: NSMaxRange(sel))
            rawLines[0] = before + rawLines[0]
            rawLines[rawLines.count - 1] = rawLines[rawLines.count - 1] + after
            string = rawLines[0]
            invalidateIntrinsicContentSize()
            onEvent?(.pasteLines(rawLines))
            return
        }
        guard let pasteString = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        if allowsInternalNewlines {
            insertText(pasteString, replacementRange: selectedRange())
            return
        }
        var rawLines = pasteString.components(separatedBy: .newlines)
        while rawLines.last?.isEmpty == true && rawLines.count > 1 {
            rawLines.removeLast()
        }
        if rawLines.count <= 1 {
            super.paste(sender)
            return
        }

        let sel = selectedRange()
        let ns = string as NSString
        let before = ns.substring(to: sel.location)
        let after = ns.substring(from: NSMaxRange(sel))

        rawLines[0] = before + rawLines[0]
        rawLines[rawLines.count - 1] = rawLines[rawLines.count - 1] + after

        string = rawLines[0]
        invalidateIntrinsicContentSize()
        onEvent?(.pasteLines(rawLines))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let handler = pasteHandler else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: charIndex, length: 0))
        return handler(pasteboard, self)
    }

    override func insertLineBreak(_ sender: Any?) {
        if allowsInternalNewlines {
            super.insertLineBreak(sender)
            return
        }
        insertNewline(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if isSlashMode {
            onEvent?(.slashSelect)
            return
        }

        if isMentionMode {
            onEvent?(.mentionSelect)
            return
        }

        if allowsInternalNewlines {
            super.insertNewline(sender)
            return
        }

        guard let ts = textStorage else { return }
        var cursor = selectedRange().location
        let text = string as NSString
        if cursor > 0, cursor < ts.length {
            var wikiRange = NSRange(location: NSNotFound, length: 0)
            let value = ts.attribute(.geoWikiLink, at: cursor, effectiveRange: &wikiRange)
            if value != nil, wikiRange.location != NSNotFound, cursor > wikiRange.location, cursor < NSMaxRange(wikiRange) {
                cursor = NSMaxRange(wikiRange)
                setSelectedRange(NSRange(location: cursor, length: 0))
            }
        }
        let allSpans = SpanExtractor.extract(from: ts, baseFont: baseFont)

        if cursor >= text.length {
            onEvent?(.split(cursorOffset: cursor, after: "", spans: []))
        } else {
            let after = text.substring(from: cursor)
            let (_, afterSpans) = InlineSpan.split(spans: allSpans, at: cursor)
            onEvent?(.split(cursorOffset: cursor, after: after, spans: afterSpans))
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if hasMultiBlockSelection {
            onEvent?(.delete)
            return
        }
        let sel = selectedRange()
        if sel.length == 0 {
            if sel.location == 0 {
                if isSlashMode {
                    isSlashMode = false
                    onEvent?(.slashDismissed)
                }
                if string.isEmpty {
                    onEvent?(.delete)
                } else if canMerge, let ts = textStorage {
                    let mergeSpans = SpanExtractor.extract(from: ts, baseFont: baseFont)
                    onEvent?(.merge(string, mergeSpans))
                }
                return
            }
        }

        super.deleteBackward(sender)

        if isSlashMode && !string.hasPrefix("/") {
            isSlashMode = false
            onEvent?(.slashDismissed)
        }

        if isMentionMode && !string.contains("[[") {
            isMentionMode = false
            onEvent?(.mentionDismissed)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isSlashMode {
            isSlashMode = false
            onEvent?(.slashDismissed)
            return
        }
        if isMentionMode {
            isMentionMode = false
            onEvent?(.mentionDismissed)
            return
        }
        onEvent?(.escapeBlock)
    }

    private(set) var isDragSelecting = false

    override func moveUpAndModifySelection(_ sender: Any?) {
        guard let lm = layoutManager else {
            super.moveUpAndModifySelection(sender)
            return
        }
        let cursor = selectedRange().location
        let glyphIndex = lm.glyphIndexForCharacter(at: max(0, cursor - 1))
        let lineRect = lm.lineFragmentRect(forGlyphAt: max(0, glyphIndex), effectiveRange: nil)
        let firstLineRect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)

        if lineRect.origin.y <= firstLineRect.origin.y {
            onEvent?(.selectUp)
        } else {
            super.moveUpAndModifySelection(sender)
        }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        guard let lm = layoutManager, let tc = textContainer else {
            super.moveDownAndModifySelection(sender)
            return
        }
        let cursor = selectedRange().location
        let textLength = (string as NSString).length
        let glyphIndex = lm.glyphIndexForCharacter(at: min(max(0, cursor), max(0, textLength - 1)))
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        lm.ensureLayout(for: tc)
        let lastGlyphIndex = max(0, lm.numberOfGlyphs - 1)
        let lastLineRect = lm.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)

        if lineRect.origin.y >= lastLineRect.origin.y {
            onEvent?(.selectDown)
        } else {
            super.moveDownAndModifySelection(sender)
        }
    }

    override func moveUp(_ sender: Any?) {
        if isSlashMode {
            onEvent?(.slashNavigateUp)
            return
        }
        if isMentionMode {
            onEvent?(.mentionNavigateUp)
            return
        }
        guard let lm = layoutManager else {
            super.moveUp(sender)
            return
        }
        let cursor = selectedRange().location
        let glyphIndex = lm.glyphIndexForCharacter(at: max(0, cursor - 1))
        let lineRect = lm.lineFragmentRect(forGlyphAt: max(0, glyphIndex), effectiveRange: nil)
        let firstLineRect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)

        if lineRect.origin.y <= firstLineRect.origin.y {
            onEvent?(.arrowUp(cursor))
        } else {
            super.moveUp(sender)
        }
    }

    override func moveDown(_ sender: Any?) {
        if isSlashMode {
            onEvent?(.slashNavigateDown)
            return
        }
        if isMentionMode {
            onEvent?(.mentionNavigateDown)
            return
        }
        guard let lm = layoutManager, let tc = textContainer else {
            super.moveDown(sender)
            return
        }
        let cursor = selectedRange().location
        let textLength = (string as NSString).length
        let glyphIndex = lm.glyphIndexForCharacter(at: min(max(0, cursor), max(0, textLength - 1)))
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        lm.ensureLayout(for: tc)
        let lastGlyphIndex = max(0, lm.numberOfGlyphs - 1)
        let lastLineRect = lm.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)

        if lineRect.origin.y >= lastLineRect.origin.y {
            onEvent?(.arrowDown(cursor))
        } else {
            super.moveDown(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        onEvent?(.indent)
    }

    override func insertBacktab(_ sender: Any?) {
        onEvent?(.outdent)
    }

    func toggleInlineFormat(style: InlineStyle) {
        let sel = selectedRange()
        if sel.length == 0 {
            toggleTypingAttribute(for: style)
            return
        }
        guard let ts = textStorage, sel.length > 0 else { return }
        let range = NSIntersectionRange(sel, NSRange(location: 0, length: ts.length))
        guard range.length > 0 else { return }

        let hasStyle = selectionHasStyle(style, in: range)

        ts.beginEditing()
        if hasStyle {
            removeStyle(style, from: range, in: ts)
        } else {
            applyStyle(style, to: range, in: ts)
        }
        ts.endEditing()

        updateFormattingState(at: selectedRange())
        onFormattingStateChange?(activeFormatting)
    }

    private func selectionHasStyle(_ style: InlineStyle, in range: NSRange) -> Bool {
        guard let ts = textStorage, range.length > 0 else { return false }
        var allHaveStyle = true
        ts.enumerateAttributes(in: range) { attrs, _, stop in
            switch style {
            case .bold:
                guard let font = attrs[.font] as? NSFont else { allHaveStyle = false; stop.pointee = true; return }
                let boldFont = SpanStyler.boldFont(for: baseFont)
                if font.fontName != boldFont.fontName { allHaveStyle = false; stop.pointee = true }
            case .italic:
                guard let font = attrs[.font] as? NSFont else { allHaveStyle = false; stop.pointee = true; return }
                let matrix = CTFontGetMatrix(font as CTFont)
                if matrix.c == 0 { allHaveStyle = false; stop.pointee = true }
            case .strikethrough:
                guard let strike = attrs[.strikethroughStyle] as? Int, strike != 0 else { allHaveStyle = false; stop.pointee = true; return }
            case .code:
                guard let font = attrs[.font] as? NSFont else { allHaveStyle = false; stop.pointee = true; return }
                let codeFont = SpanStyler.codeFont(for: baseFont)
                if font.fontName != codeFont.fontName || font.pointSize != codeFont.pointSize { allHaveStyle = false; stop.pointee = true }
            case .highlight:
                guard let isHighlight = attrs[.geoHighlight] as? Bool, isHighlight else { allHaveStyle = false; stop.pointee = true; return }
            case .wikiLink:
                break
            case .wikiLinkWithMeta:
                break
            case .math:
                break
            case .link:
                break
            case .autoLink:
                break
            case .embed:
                break
            case .tag:
                break
            }
        }
        return allHaveStyle
    }

    func applyStyle(_ style: InlineStyle, to range: NSRange, in ts: NSTextStorage) {
        switch style {
        case .bold:
            ts.addAttribute(.font, value: SpanStyler.boldFont(for: baseFont), range: range)
        case .italic:
            ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let current = value as? NSFont ?? baseFont
                let isBold = current.fontName == SpanStyler.boldFont(for: baseFont).fontName
                let newFont = isBold ? SpanStyler.boldItalicFont(for: baseFont) : SpanStyler.italicFont(for: baseFont)
                ts.addAttribute(.font, value: newFont, range: subRange)
            }
        case .strikethrough:
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .code:
            ts.addAttribute(.font, value: SpanStyler.codeFont(for: baseFont), range: range)
            ts.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
        case .highlight:
            ts.addAttribute(.backgroundColor, value: HighlightStyle.color, range: range)
            ts.addAttribute(.geoHighlight, value: true, range: range)
        case .wikiLink:
            break
        case .wikiLinkWithMeta:
            break
        case .math:
            break
        case .link:
            break
        case .autoLink:
            break
        case .embed:
            break
        case .tag:
            break
        }
    }

    private func removeStyle(_ style: InlineStyle, from range: NSRange, in ts: NSTextStorage) {
        switch style {
        case .bold:
            ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let current = value as? NSFont ?? baseFont
                let matrix = CTFontGetMatrix(current as CTFont)
                let isItalic = matrix.c != 0
                let newFont = isItalic ? SpanStyler.italicFont(for: baseFont) : baseFont
                ts.addAttribute(.font, value: newFont, range: subRange)
            }
        case .italic:
            ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let current = value as? NSFont ?? baseFont
                let isBold = current.fontName == SpanStyler.boldFont(for: baseFont).fontName ||
                             current.fontName == SpanStyler.boldItalicFont(for: baseFont).fontName
                let newFont = isBold ? SpanStyler.boldFont(for: baseFont) : baseFont
                ts.addAttribute(.font, value: newFont, range: subRange)
            }
        case .strikethrough:
            ts.removeAttribute(.strikethroughStyle, range: range)
        case .code:
            ts.addAttribute(.font, value: baseFont, range: range)
            ts.removeAttribute(.backgroundColor, range: range)
        case .highlight:
            ts.removeAttribute(.geoHighlight, range: range)
            ts.removeAttribute(.backgroundColor, range: range)
        case .wikiLink:
            break
        case .wikiLinkWithMeta:
            break
        case .math:
            break
        case .link:
            ts.removeAttribute(.geoLink, range: range)
            ts.removeAttribute(.underlineStyle, range: range)
            ts.addAttribute(.foregroundColor, value: baseForeground, range: range)
        case .autoLink:
            break
        case .embed:
            break
        case .tag:
            break
        }
    }

    private func toggleTypingAttribute(for style: InlineStyle) {
        var attrs = typingAttributes
        switch style {
        case .bold:
            let boldFont = SpanStyler.boldFont(for: baseFont)
            if let current = attrs[.font] as? NSFont, current.fontName == boldFont.fontName {
                let matrix = CTFontGetMatrix(current as CTFont)
                let isItalic = matrix.c != 0
                attrs[.font] = isItalic ? SpanStyler.italicFont(for: baseFont) : baseFont
            } else {
                let current = attrs[.font] as? NSFont ?? baseFont
                let matrix = CTFontGetMatrix(current as CTFont)
                let isItalic = matrix.c != 0
                attrs[.font] = isItalic ? SpanStyler.boldItalicFont(for: baseFont) : boldFont
            }
        case .italic:
            let current = attrs[.font] as? NSFont ?? baseFont
            let matrix = CTFontGetMatrix(current as CTFont)
            if matrix.c != 0 {
                let isBold = current.fontName == SpanStyler.boldFont(for: baseFont).fontName ||
                             current.fontName == SpanStyler.boldItalicFont(for: baseFont).fontName
                attrs[.font] = isBold ? SpanStyler.boldFont(for: baseFont) : baseFont
            } else {
                let isBold = current.fontName == SpanStyler.boldFont(for: baseFont).fontName
                attrs[.font] = isBold ? SpanStyler.boldItalicFont(for: baseFont) : SpanStyler.italicFont(for: baseFont)
            }
        case .strikethrough:
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                attrs.removeValue(forKey: .strikethroughStyle)
            } else {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        case .code:
            let codeFont = SpanStyler.codeFont(for: baseFont)
            if let current = attrs[.font] as? NSFont, current.fontName == codeFont.fontName && current.pointSize == codeFont.pointSize {
                attrs[.font] = baseFont
                attrs.removeValue(forKey: .backgroundColor)
            } else {
                attrs[.font] = codeFont
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
        case .highlight:
            if let isHighlight = attrs[.geoHighlight] as? Bool, isHighlight {
                attrs.removeValue(forKey: .geoHighlight)
                attrs.removeValue(forKey: .backgroundColor)
            } else {
                attrs[.geoHighlight] = true
                attrs[.backgroundColor] = HighlightStyle.color
            }
        case .wikiLink:
            break
        case .wikiLinkWithMeta:
            break
        case .math:
            break
        case .link:
            break
        case .autoLink:
            break
        case .embed:
            break
        case .tag:
            break
        }
        typingAttributes = attrs
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler.handlePerformKeyEquivalent(with: event, in: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
