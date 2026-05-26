import AppKit
import SwiftUI

struct BlockTextEditorView: NSViewRepresentable {
    let blockId: UUID
    let content: String
    let spans: [InlineSpan]
    let kind: EditorBlockKind
    let fontSize: CGFloat
    let focusCoordinator: EditorFocusCoordinator
    let isSlashMode: Bool
    var isMentionMode: Bool = false
    var allowsInternalNewlines: Bool = false
    var canMerge: Bool = true
    var hasMultiBlockSelection: Bool = false
    var pasteHandler: ((NSPasteboard, NSTextView) -> Bool)?
    var highlightRanges: [NSRange] = []
    var activeHighlightRange: NSRange? = nil
    let onEvent: (BlockEditorEvent) -> Void
    var onDragOutside: ((NSPoint) -> Void)?

    func makeNSView(context: Context) -> BlockNSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let tv = BlockNSTextView(frame: .zero, textContainer: textContainer)
        tv.autoresizingMask = [.width]
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isRichText = true
        tv.usesRuler = false
        tv.usesFontPanel = false
        tv.usesInspectorBar = false
        tv.allowsUndo = true
        tv.isAutomaticTextCompletionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false

        let font = EditorTypography.fontForKind(kind, baseSize: fontSize)
        tv.font = font
        tv.baseFont = font
        tv.baseForeground = Palette.editorForeground
        tv.lineHeightMultiple = EditorTypography.lineHeightForKind(kind)
        tv.textColor = Palette.editorForeground
        tv.string = content
        let ts = tv.textStorage!
        ts.setAttributes(tv.baseAttributes, range: NSRange(location: 0, length: ts.length))
        SpanStyler.apply(spans: spans, to: ts, baseFont: font)
        Self.applyFindHighlights(to: ts, highlights: highlightRanges, active: activeHighlightRange)
        tv.typingAttributes = tv.baseAttributes

        tv.blockId = blockId
        tv.blockKind = kind
        tv.focusCoordinator = focusCoordinator
        context.coordinator.bind(tv)
        context.coordinator.lastAppliedSpans = spans
        context.coordinator.lastAppliedKind = kind
        context.coordinator.lastSyncedContent = content
        if case .codeBlock = kind {
            tv.applySyntaxHighlighting()
        }
        focusCoordinator.register(tv, for: blockId)
        return tv
    }

    func updateNSView(_ tv: BlockNSTextView, context: Context) {
        context.coordinator.parent = self
        tv.isSlashMode = isSlashMode
        tv.isMentionMode = isMentionMode
        tv.allowsInternalNewlines = allowsInternalNewlines
        tv.canMerge = canMerge
        tv.hasMultiBlockSelection = hasMultiBlockSelection
        tv.pasteHandler = pasteHandler

        let kindChanged = context.coordinator.lastAppliedKind != kind
        if kindChanged {
            tv.blockKind = kind
            let newFont = EditorTypography.fontForKind(kind, baseSize: fontSize)
            if tv.baseFont.fontName != newFont.fontName || tv.baseFont.pointSize != newFont.pointSize {
                tv.font = newFont
                tv.baseFont = newFont
            }
            tv.lineHeightMultiple = EditorTypography.lineHeightForKind(kind)
            context.coordinator.lastAppliedKind = kind
        }
        let foregroundChanged = tv.baseForeground != Palette.editorForeground
        tv.baseForeground = Palette.editorForeground

        let isCodeBlock = { if case .codeBlock = kind { return true }; return false }()

        if foregroundChanged || kindChanged {
            tv.textColor = Palette.editorForeground
            tv.typingAttributes = tv.baseAttributes
            let ts = tv.textStorage!
            ts.beginEditing()
            ts.setAttributes(tv.baseAttributes, range: NSRange(location: 0, length: ts.length))
            SpanStyler.apply(spans: spans, to: ts, baseFont: tv.baseFont)
            ts.endEditing()
            if isCodeBlock { tv.applySyntaxHighlighting() }
            context.coordinator.lastAppliedSpans = spans
        }

        if content == context.coordinator.lastSyncedContent {
            Self.applyFindHighlights(to: tv.textStorage!, highlights: highlightRanges, active: activeHighlightRange)
            return
        }
        if tv.string != content {
            let sel = tv.selectedRange()
            tv.string = content
            context.coordinator.lastSyncedContent = content
            let safe = min(sel.location, (content as NSString).length)
            tv.setSelectedRange(NSRange(location: safe, length: 0))
            let ts = tv.textStorage!
            ts.beginEditing()
            ts.setAttributes(tv.baseAttributes, range: NSRange(location: 0, length: ts.length))
            if !spans.isEmpty {
                SpanStyler.apply(spans: spans, to: ts, baseFont: tv.baseFont)
            }
            ts.endEditing()
            if isCodeBlock { tv.applySyntaxHighlighting() }
            context.coordinator.lastAppliedSpans = spans
            tv.invalidateIntrinsicContentSize()
        } else if context.coordinator.lastAppliedSpans != spans {
            let ts = tv.textStorage!
            ts.beginEditing()
            ts.setAttributes(tv.baseAttributes, range: NSRange(location: 0, length: ts.length))
            if !spans.isEmpty {
                SpanStyler.apply(spans: spans, to: ts, baseFont: tv.baseFont)
            }
            ts.endEditing()
            if isCodeBlock { tv.applySyntaxHighlighting() }
            context.coordinator.lastAppliedSpans = spans
            context.coordinator.lastSyncedContent = content
        }

        Self.applyFindHighlights(to: tv.textStorage!, highlights: highlightRanges, active: activeHighlightRange)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BlockNSTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width
        let width = proposed.isFinite && proposed > 1 ? proposed : max(nsView.bounds.width, 1)
        return TextViewHeightCalculator.sizeThatFits(width: width, textView: nsView)
    }

    private static func applyFindHighlights(to ts: NSTextStorage, highlights: [NSRange], active: NSRange?) {
        for range in highlights {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: ts.length))
            if safeRange.length > 0 {
                ts.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: safeRange)
            }
        }
        if let active {
            let safeRange = NSIntersectionRange(active, NSRange(location: 0, length: ts.length))
            if safeRange.length > 0 {
                ts.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.5), range: safeRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: BlockTextEditorView
        var lastSyncedContent: String?
        var lastAppliedSpans: [InlineSpan]?
        var lastAppliedKind: EditorBlockKind?

        init(_ parent: BlockTextEditorView) {
            self.parent = parent
        }

        func bind(_ tv: BlockNSTextView) {
            tv.onWillEmitContent = { [weak self] content in
                self?.lastSyncedContent = content
            }
            tv.onEvent = { [weak self] event in
                guard let self else { return }
                if case .contentChange(let content, let spans) = event {
                    self.lastSyncedContent = content
                    self.lastAppliedSpans = spans
                }
                self.parent.onEvent(event)
            }
            tv.onDragOutside = { [weak self] windowPoint in
                self?.parent.onDragOutside?(windowPoint)
            }
        }
    }
}
