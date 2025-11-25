import SwiftUI
import AppKit

struct BlockEditorView: View {
    let block: BlocksStore.Block
    @EnvironmentObject var blocksStore: BlocksStore
    @Environment(\.dismiss) var dismiss
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isTodoMode: Bool = false
    @State private var saveWorkItem: DispatchWorkItem?
    
    @FocusState private var focusedField: Field?
    
    private enum Field {
        case title
        case content
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Title Field
                    TextField("Untitled", text: $title)
                        .font(.system(size: 20, weight: .semibold, design: .default))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .title)
                        .onSubmit {
                            if !isTodoMode {
                                focusedField = .content
                            }
                        }
                    
                    Divider()
                    
                    if isTodoMode {
                        // Dedicated Todo List UI
                        TodoListView(markdown: $content)
                    } else {
                        // Standard Markdown Editor
                        MacEditorTextView(text: $content)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 500)
                            .focused($focusedField, equals: .content)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .onAppear {
            loadContent()
        }
        .onDisappear {
            // Save immediately on close
            save()
        }
        .onChange(of: title) { _ in debouncedSave() }
        .onChange(of: content) { _ in debouncedSave() }
    }
    
    private func loadContent() {
        let fullText = block.markdown
        let lines = fullText.components(separatedBy: .newlines)
        
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            title = String(firstLine.dropFirst(2))
            content = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = block.title.replacingOccurrences(of: "# ", with: "")
            content = fullText.replacingOccurrences(of: "# \(block.title)\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Determine mode based on title
        isTodoMode = title.localizedCaseInsensitiveContains("To-Do List")
    }
    
    private func debouncedSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem {
            save()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    
    private func save() {
        // If deleted, block might be invalid, but we check block existence in store?
        // For now, just save.
        let newMarkdown = "# \(title)\n\n\(content)"
        blocksStore.updateBlock(block, newMarkdown: newMarkdown)
    }
}

/// A wrapper around NSTextView for standard markdown editing.
struct MacEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var font: Font = .body
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = CustomNSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = false
        let monoFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.2
        textView.font = monoFont
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: monoFont,
            .paragraphStyle: paragraphStyle
        ]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 8)

        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        
        scrollView.documentView = textView
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let monoFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let paragraphStyle: NSMutableParagraphStyle = {
            if let style = textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle {
                return style
            }
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            return style
        }()
        if textView.font != monoFont {
            textView.font = monoFont
        }
        textView.typingAttributes[.font] = monoFont
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        textView.defaultParagraphStyle = paragraphStyle

        context.coordinator.isUpdating = true
        
        // Preserve selection safely
        let previousSelection = textView.selectedRange()
        
        // Safely replace characters to avoid breaking input session analytics
        if let textStorage = textView.textStorage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .paragraphStyle: paragraphStyle
            ]
            if textStorage.string != text {
                textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            } else {
                textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
            }
        } else {
            textView.string = text
        }

        // Only restore selection if we have focus, otherwise we might steal it or confuse the input system
        if textView.window?.firstResponder == textView {
            let safeLocation = min(previousSelection.location, text.count)
            let safeLength = min(previousSelection.length, text.count - safeLocation)
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
        }
        
        context.coordinator.isUpdating = false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacEditorTextView
        var isUpdating = false
        
        init(_ parent: MacEditorTextView) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isUpdating else { return }
            parent.text = textView.string
        }
    }
}

// Subclass to fix some autosizing/scroll quirks
class CustomNSTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        // layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).size
    }
}
