import SwiftUI
import AppKit

struct BlockRowConfiguration: Equatable {
    let block: EditorBlock
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    let isFocused: Bool
    let isSelected: Bool
    let isDragSource: Bool
    let hasMultiBlockSelection: Bool
    let fontSize: CGFloat
    var highlightRanges: [NSRange] = []
    var activeHighlightRange: NSRange? = nil
    let isSlashMode: Bool
    let isMentionMode: Bool
    let contentBaseURL: URL?
    var accentColor: Color? = nil

    // Custom equality skips EditorBlock's sourceRange / contentRange / parentId,
    // which shift on every earlier-block edit without affecting rendering.
    // Including them in equality made every keystroke invalidate every later
    // visible row's config — forcing N body re-evals per keystroke for free.
    //
    // Split into early-return clauses to avoid Swift's type-checker timeout
    // on long `&&` chains.
    static func == (lhs: BlockRowConfiguration, rhs: BlockRowConfiguration) -> Bool {
        if lhs.block.id != rhs.block.id { return false }
        if lhs.isFocused != rhs.isFocused { return false }
        if lhs.isSelected != rhs.isSelected { return false }
        if lhs.isDragSource != rhs.isDragSource { return false }
        if lhs.hasMultiBlockSelection != rhs.hasMultiBlockSelection { return false }
        if lhs.isSlashMode != rhs.isSlashMode { return false }
        if lhs.isMentionMode != rhs.isMentionMode { return false }
        if lhs.isCollapsed != rhs.isCollapsed { return false }
        if lhs.hasChildren != rhs.hasChildren { return false }
        if lhs.depth != rhs.depth { return false }
        if lhs.fontSize != rhs.fontSize { return false }
        if lhs.accentColor != rhs.accentColor { return false }
        if lhs.contentBaseURL != rhs.contentBaseURL { return false }
        if lhs.activeHighlightRange != rhs.activeHighlightRange { return false }
        if lhs.highlightRanges != rhs.highlightRanges { return false }
        if lhs.block.kind != rhs.block.kind { return false }
        if lhs.block.depth != rhs.block.depth { return false }
        if lhs.block.collapsed != rhs.block.collapsed { return false }
        if lhs.block.insideBlockquote != rhs.block.insideBlockquote { return false }
        if lhs.block.indent != rhs.block.indent { return false }
        if lhs.block.prefix != rhs.block.prefix { return false }
        if lhs.block.cleanContent != rhs.block.cleanContent { return false }
        if lhs.block.spans != rhs.block.spans { return false }
        if lhs.block.rawText != rhs.block.rawText { return false }
        return true
    }
}

struct BlockRowCallbacks {
    let attachmentHandler: ((NSPasteboard, NSTextView) -> Bool)?
    let onEvent: (BlockEditorEvent) -> Void
    let onDragOutside: ((NSPoint) -> Void)?
    let onToggleCheckbox: () -> Void
    let onHandleClick: () -> Void
    let onDragStart: () -> Void
    let onToggleCollapse: () -> Void
}

struct BlockRowView<MenuContent: View>: View {
    let config: BlockRowConfiguration
    let callbacks: BlockRowCallbacks
    let focusCoordinator: EditorFocusCoordinator
    @ViewBuilder let contextMenuContent: () -> MenuContent

    @State private var isHovered = false
    @State private var loadedImage: NSImage?

    private var block: EditorBlock { config.block }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dragHandle
            blockChrome
            blockContent
        }
        .padding(.leading, CGFloat(config.depth) * 24)
        .padding(.vertical, blockVerticalPadding)
        .background(blockBackground)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: BlockRowBoundsKey.self,
                    value: [config.block.id: geo.frame(in: .named("editor"))]
                )
            }
        )
        .accessibilityElement(children: .contain)
        .opacity(config.isDragSource ? 0.4 : 1.0)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var blockBackground: some View {
        if config.isSelected {
            RoundedRectangle(cornerRadius: 4).fill(Palette.accent.opacity(0.1))
        } else if config.isFocused {
            RoundedRectangle(cornerRadius: 4).fill(Palette.accent.opacity(0.04))
        }
    }

    private var dragHandle: some View {
        HStack(spacing: 0) {
            if config.hasChildren {
                Image(systemName: config.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Palette.tertiaryForeground.opacity(0.6))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
                    .accessibilityLabel(config.isCollapsed ? "Expand" : "Collapse")
                    .accessibilityAddTraits(.isButton)
                    .onTapGesture { callbacks.onToggleCollapse() }
            } else {
                Color.clear.frame(width: 12, height: 20)
            }
            ZStack {
                if isHovered || config.isSelected {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Palette.tertiaryForeground.opacity(0.5))
                }
            }
            .frame(width: 16, height: 20)
            .contentShape(Rectangle())
            .accessibilityLabel("Reorder block")
            .accessibilityAddTraits(.isButton)
            .onTapGesture { callbacks.onHandleClick() }
            .onDrag {
                callbacks.onDragStart()
                return NSItemProvider(object: block.id.uuidString as NSString)
            }
            .contextMenu { contextMenuContent() }
        }
    }

    private var blockVerticalPadding: CGFloat {
        switch block.kind {
        case .heading(let level):
            return level <= 2 ? 6 : 3
        case .horizontalRule:
            return 8
        default:
            return 1
        }
    }

    private var chromeColor: Color {
        config.accentColor ?? Palette.tertiaryForeground
    }

    private func chromeTopFor(elementHeight: CGFloat) -> CGFloat {
        let font = FontManager.geistMono(size: config.fontSize)
        let baseline = 2 + font.ascender * 1.3
        let capCenter = baseline - font.capHeight * 0.5
        return capCenter - elementHeight * 0.5
    }

    @ViewBuilder
    private var blockChrome: some View {
        HStack(spacing: 0) {
            // List/checkbox lines that live inside a blockquote (`> - item`,
            // `> 1. [ ] task`) carry their own list chrome AND the quote bar.
            if block.insideBlockquote {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill((config.accentColor ?? Palette.accent).opacity(0.5))
                    .frame(width: 3)
                    .padding(.trailing, 8)
            }
            listChrome
        }
    }

    @ViewBuilder
    private var listChrome: some View {
        switch block.kind {
        case .bulletItem:
            Circle()
                .fill(chromeColor)
                .frame(width: 5, height: 5)
                .frame(width: 20)
                .padding(.top, chromeTopFor(elementHeight: 5))
                .padding(.trailing, 4)
        case .orderedItem(let number):
            AppKitLabel(
                text: "\(number).",
                font: FontManager.geistMono(size: config.fontSize),
                color: NSColor(chromeColor),
                alignment: .right
            )
            .frame(width: 24)
            .padding(.top, chromeTopFor(elementHeight: config.fontSize))
            .padding(.trailing, 4)
        case .checkboxItem(let checked, let marker):
            HStack(spacing: 4) {
                // Ordered checkbox (`1. [ ] text`): marker is "1."/"2." — show
                // the number before the checkbox icon, mirroring orderedItem chrome.
                if marker.hasSuffix(".") {
                    AppKitLabel(
                        text: marker,
                        font: FontManager.geistMono(size: config.fontSize),
                        color: NSColor(chromeColor),
                        alignment: .right
                    )
                    .frame(width: 24)
                    .padding(.top, chromeTopFor(elementHeight: config.fontSize))
                }
                Button(action: callbacks.onToggleCheckbox) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: config.fontSize * 0.85))
                        .foregroundColor(checked ? (config.accentColor ?? Palette.accent) : chromeColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Task checkbox")
                .accessibilityValue(checked ? "Completed" : "Incomplete")
                .padding(.top, chromeTopFor(elementHeight: config.fontSize * 0.85))
            }
            .frame(width: marker.hasSuffix(".") ? 48 : 20)
            .padding(.trailing, 4)
        case .blockquote:
            RoundedRectangle(cornerRadius: 1.5)
                .fill((config.accentColor ?? Palette.accent).opacity(0.5))
                .frame(width: 3)
                .padding(.trailing, 8)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.kind {
        case .horizontalRule:
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.tertiaryForeground.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: 2)
                .padding(.vertical, 8)
        case .callout:
            calloutEditor
        case .toggle:
            toggleEditor
        case .mathBlock:
            mathBlockView
        case .codeBlock:
            codeBlockEditor
        case .table:
            tableEditor
        case .image:
            imageView
        default:
            BlockTextEditorView(
                blockId: block.id, content: block.content, spans: block.spans, kind: block.kind,
                fontSize: config.fontSize, focusCoordinator: focusCoordinator,
                isSlashMode: config.isSlashMode, isMentionMode: config.isMentionMode,
                hasMultiBlockSelection: config.hasMultiBlockSelection && config.isSelected,
                pasteHandler: callbacks.attachmentHandler,
                highlightRanges: config.highlightRanges,
                activeHighlightRange: config.activeHighlightRange,
                onEvent: callbacks.onEvent,
                onDragOutside: callbacks.onDragOutside
            )
            .frame(maxWidth: .infinity)
            .transaction { $0.animation = nil }
        }
    }

    private var mathBlockView: some View {
        Group {
            if config.isFocused {
                BlockTextEditorView(
                    blockId: block.id, content: block.mathContent ?? "", spans: [], kind: block.kind,
                    fontSize: config.fontSize, focusCoordinator: focusCoordinator,
                    isSlashMode: false, allowsInternalNewlines: true, canMerge: false,
                    hasMultiBlockSelection: config.hasMultiBlockSelection && config.isSelected,
                    pasteHandler: callbacks.attachmentHandler, onEvent: callbacks.onEvent,
                    onDragOutside: callbacks.onDragOutside
                )
                .font(.system(size: config.fontSize, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 12)
            } else {
                MathBlockDisplayWrapper(
                    latex: block.mathContent ?? block.content,
                    fontSize: config.fontSize
                )
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Palette.secondaryBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @State private var codeBlockHovered = false

    private var codeBlockBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? SyntaxHighlighter.codeBlockBackground.dark
                : SyntaxHighlighter.codeBlockBackground.light
        })
    }

    private var codeBlockEditor: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                BlockTextEditorView(
                    blockId: block.id, content: block.codeContent ?? "", spans: [], kind: block.kind,
                    fontSize: config.fontSize, focusCoordinator: focusCoordinator,
                    isSlashMode: false, allowsInternalNewlines: true, canMerge: false,
                    hasMultiBlockSelection: config.hasMultiBlockSelection && config.isSelected,
                    pasteHandler: callbacks.attachmentHandler, onEvent: callbacks.onEvent,
                    onDragOutside: callbacks.onDragOutside
                )
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if codeBlockHovered {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.codeContent ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Palette.tertiaryForeground)
                            .padding(5)
                            .background(Palette.secondaryBackground.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                if let lang = block.codeLanguage, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: config.fontSize * 0.65, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.tertiaryForeground.opacity(0.7))
                }
            }
            .padding(.top, 8).padding(.trailing, 10)
        }
        .background(codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { codeBlockHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: codeBlockHovered)
    }

    @State private var tableModel: TableModel?
    @State private var lastParsedTableRaw: String?

    private var tableEditor: some View {
        Group {
            if tableModel != nil {
                TableEditorView(
                    table: Binding(
                        get: { tableModel ?? TableModel.defaultTable() },
                        set: { newTable in
                            tableModel = newTable
                        }
                    ),
                    fontSize: config.fontSize,
                    onChanged: {
                        guard let model = tableModel else { return }
                        let markdown = model.serialize()
                        // Record what we're about to emit so the round-trip
                        // through .onChange(of: block.rawText) skips re-parsing
                        // markdown we just generated.
                        lastParsedTableRaw = markdown
                        callbacks.onEvent(.contentChange(markdown, []))
                    }
                )
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Invalid table")
                    .font(FontManager.geistMonoFont(size: config.fontSize))
                    .foregroundColor(Palette.tertiaryForeground)
                    .padding(10)
            }
        }
        .onAppear {
            tableModel = TableModel.parse(markdown: block.rawText)
            lastParsedTableRaw = block.rawText
        }
        .onChange(of: block.rawText) { _, newValue in
            guard newValue != lastParsedTableRaw else { return }
            if let parsed = TableModel.parse(markdown: newValue), parsed != tableModel {
                tableModel = parsed
            }
            lastParsedTableRaw = newValue
        }
    }

    private var calloutEditor: some View {
        let (calloutType, calloutTitle): (CalloutType, String?) = {
            if case .callout(let t, let title) = block.kind { return (t, title) }
            return (.note, nil)
        }()
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calloutType.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: calloutType.icon)
                        .font(.system(size: config.fontSize * 0.9, weight: .semibold))
                        .foregroundColor(calloutType.color)
                    Text(calloutTitle ?? calloutType.displayName)
                        .font(.system(size: config.fontSize, weight: .bold))
                        .foregroundColor(calloutType.color)
                }
                BlockTextEditorView(
                    blockId: block.id, content: block.calloutContent ?? "", spans: [], kind: block.kind,
                    fontSize: config.fontSize, focusCoordinator: focusCoordinator,
                    isSlashMode: false, allowsInternalNewlines: true, canMerge: false,
                    hasMultiBlockSelection: config.hasMultiBlockSelection && config.isSelected,
                    pasteHandler: callbacks.attachmentHandler, onEvent: callbacks.onEvent,
                    onDragOutside: callbacks.onDragOutside
                )
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(calloutType.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @State private var toggleExpanded: Bool? = nil

    private var toggleEditor: some View {
        let expanded: Bool = {
            if let override = toggleExpanded { return override }
            if case .toggle(let e) = block.kind { return e }
            return false
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.tertiaryForeground)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: expanded)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let newState = !expanded
                        toggleExpanded = newState
                        callbacks.onEvent(.contentChange(block.content, block.spans))
                        DispatchQueue.main.async {
                            callbacks.onToggleCollapse()
                        }
                    }
                Text(block.toggleTitle ?? "")
                    .font(FontManager.geistMonoFont(size: config.fontSize))
                    .foregroundColor(Color(Palette.editorForeground))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 0)

            if expanded {
                BlockTextEditorView(
                    blockId: block.id, content: block.toggleContent ?? "", spans: [], kind: block.kind,
                    fontSize: config.fontSize, focusCoordinator: focusCoordinator,
                    isSlashMode: false, allowsInternalNewlines: true, canMerge: false,
                    hasMultiBlockSelection: config.hasMultiBlockSelection && config.isSelected,
                    pasteHandler: callbacks.attachmentHandler, onEvent: callbacks.onEvent,
                    onDragOutside: callbacks.onDragOutside
                )
                .padding(.leading, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.tertiaryForeground.opacity(0.04))
                        .padding(.leading, 20)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: expanded)
    }

    @State private var isImageExpanded = false

    private var imageView: some View {
        let (altText, urlString): (String, String) = {
            if case .image(let alt, let url) = block.kind { return (alt, url) }
            return ("", "")
        }()
        let resolvedURL = resolveURL(urlString)
        return VStack(alignment: .leading, spacing: 4) {
            if let resolvedURL {
                if resolvedURL.isFileURL {
                    Group {
                        if let loadedImage {
                            Image(nsImage: loadedImage).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle().fill(Palette.secondaryBackground).frame(height: 100)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { if loadedImage != nil { isImageExpanded = true } }
                    .task(id: resolvedURL) {
                        loadedImage = await Task.detached {
                            NSImage(contentsOf: resolvedURL)
                        }.value
                    }
                } else {
                    AsyncImage(url: resolvedURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Rectangle().fill(Palette.secondaryBackground).frame(height: 100)
                            .overlay(Image(systemName: "photo").foregroundColor(Palette.tertiaryForeground))
                    }
                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if !altText.isEmpty {
                Text(altText).font(.system(size: config.fontSize * 0.8))
                    .foregroundColor(Palette.tertiaryForeground).padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isImageExpanded) { _, expanded in
            if expanded, let loadedImage {
                ImageExpandedWindow.show(image: loadedImage) {
                    isImageExpanded = false
                }
            }
        }
    }

    private func resolveURL(_ urlString: String) -> URL? {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") || urlString.hasPrefix("file://") {
            return URL(string: urlString)
        }
        if let decoded = urlString.removingPercentEncoding, let base = config.contentBaseURL {
            return base.appendingPathComponent(decoded)
        }
        return URL(string: urlString)
    }

}

struct EquatableBlockRow: View, Equatable {
    let config: BlockRowConfiguration
    let callbacks: BlockRowCallbacks
    let focusCoordinator: EditorFocusCoordinator
    @ViewBuilder let contextMenuContent: () -> AnyView

    static func == (lhs: EquatableBlockRow, rhs: EquatableBlockRow) -> Bool {
        // Safe now that Phase 1 callbacks capture block.id (not Int index).
        // BlockRowConfiguration contains the full EditorBlock, so any content,
        // parentId, depth, span, or selection-state change forces a re-render.
        lhs.config == rhs.config
    }

    var body: some View {
        BlockRowView(
            config: config,
            callbacks: callbacks,
            focusCoordinator: focusCoordinator,
            contextMenuContent: contextMenuContent
        )
    }
}

private struct AppKitLabel: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.alignment = alignment
    }
}

private struct MathBlockDisplayView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributedString)
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.backgroundColor = .clear
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = attributedString
    }
}

private struct MathBlockDisplayWrapper: View {
    let latex: String
    let fontSize: CGFloat

    var body: some View {
        let rendered = MathRenderer.render(latex: latex, fontSize: fontSize, color: .labelColor)
        MathBlockDisplayView(attributedString: rendered)
            .frame(maxWidth: .infinity)
    }
}
