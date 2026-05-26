import Foundation

/// Tagged sequence used by the parallel block parser. Fence-bound blocks
/// (code/math/table/toggle/callout) are built synchronously during the
/// state-machine scan; independent per-line blocks are deferred so they
/// can be parsed in parallel after the scan completes.
private enum ParseSlot {
    case line(NSRange)
    case block(EditorBlock)
}

/// Hashable wrapper that hashes by (utf8 length, first 64 bytes) instead of
/// the full string. Equality is still full-string compare so dict correctness
/// is preserved on collision. For large blocks (50KB code/math) this drops
/// the per-block hash cost from O(N) to O(64).
private struct RawKey: Hashable {
    let raw: String
    private let prefixHash: Int

    init(_ raw: String) {
        self.raw = raw
        var hasher = Hasher()
        hasher.combine(raw.utf8.count)
        for byte in raw.utf8.prefix(64) {
            hasher.combine(byte)
        }
        self.prefixHash = hasher.finalize()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(prefixHash)
    }

    static func == (lhs: RawKey, rhs: RawKey) -> Bool {
        lhs.raw == rhs.raw
    }
}

enum MarkdownBlockParser {

    private static let headingRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)(#{1,6})\\s", options: [])) ?? NSRegularExpression()
    }()

    private static let toggleRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^>>\\s*\\[(>|v)\\]\\s*(.*)$", options: [])) ?? NSRegularExpression()
    }()

    private static let calloutRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^>\\s*\\[!(\\w+)\\]\\s*(.*)?$", options: [])) ?? NSRegularExpression()
    }()

    private static let blockquoteRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)((?:>\\s?)+)", options: [])) ?? NSRegularExpression()
    }()

    private static let checkboxRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+\\[([ xX])\\]\\s", options: [])) ?? NSRegularExpression()
    }()

    private static let orderedCheckboxRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s+\\[([ xX])\\]\\s", options: [])) ?? NSRegularExpression()
    }()

    private static let bulletRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)([-*+])\\s", options: [])) ?? NSRegularExpression()
    }()

    static let orderedRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s", options: [])) ?? NSRegularExpression()
    }()

    static let imageRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^)]+)\\)\\s*$", options: [])) ?? NSRegularExpression()
    }()

    static func parseImageMarkdown(_ text: String) -> (alt: String, url: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = imageRegex.firstMatch(in: trimmed, range: range) else { return nil }
        let alt = match.range(at: 1).location != NSNotFound ? (trimmed as NSString).substring(with: match.range(at: 1)) : ""
        let url = match.range(at: 2).location != NSNotFound ? (trimmed as NSString).substring(with: match.range(at: 2)) : ""
        return (alt, url)
    }

    /// Parallel block parser.
    ///
    /// Pass 1 (serial state machine, O(N) lines): walks lines tracking fence state.
    /// Fence-bound blocks (code/math/table/toggle/callout) are built immediately
    /// since they span multiple lines and depend on lookahead. Independent
    /// per-line blocks (paragraph, heading, list, blockquote, checkbox, image,
    /// hr, empty) are deferred as `.line(NSRange)` slots — each is a pure
    /// function of one line.
    ///
    /// Pass 2 (parallel via DispatchQueue.concurrentPerform): each deferred
    /// line is parsed via `parseLine`. Pure function, thread-safe regex.
    /// Results written to disjoint indices of a buffer pointer. Gated at
    /// ≥256 deferred lines to avoid thread overhead on small docs.
    ///
    /// Pass 3 (serial flatten): slots collapsed into the final block array
    /// in original order.
    ///
    /// Pass 4 (parallel inline parse): non-special blocks get their
    /// `cleanContent` + `spans` filled via `InlineParser.parse`, also in
    /// parallel via `concurrentPerform`. Gated at ≥8 eligible blocks.
    static func parse(markdown: String) -> BlockDocument {
        let nsText = markdown as NSString
        var slots: [ParseSlot] = []
        slots.reserveCapacity(64)
        var cursor = 0
        var inCodeBlock = false
        var codeBlockStart = 0
        var codeBlockLanguage: String?
        var codeBlockFenceLen = 0
        var inMathBlock = false
        var mathBlockStart = 0
        var inTable = false
        var tableStart = 0

        while cursor < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let lineText = nsText.substring(with: lineRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

            if inTable && !(trimmed.hasPrefix("|") && trimmed.hasSuffix("|")) {
                let fullRange = NSRange(location: tableStart, length: cursor - tableStart)
                let raw = nsText.substring(with: fullRange)
                slots.append(.block(EditorBlock(
                    id: UUID(), kind: .table,
                    sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                    contentRange: fullRange
                )))
                inTable = false
            }

            if trimmed == "$$" && !inCodeBlock {
                if inMathBlock {
                    let fullRange = NSRange(location: mathBlockStart, length: NSMaxRange(lineRange) - mathBlockStart)
                    let raw = nsText.substring(with: fullRange)
                    slots.append(.block(EditorBlock(
                        id: UUID(), kind: .mathBlock,
                        sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                        contentRange: fullRange
                    )))
                    inMathBlock = false
                } else {
                    inMathBlock = true
                    mathBlockStart = lineRange.location
                }
                cursor = NSMaxRange(lineRange)
                continue
            }

            if inMathBlock {
                cursor = NSMaxRange(lineRange)
                continue
            }

            let fenceLen = trimmed.prefix(while: { $0 == "`" }).count
            if fenceLen >= 3 {
                if inCodeBlock {
                    let afterFence = String(trimmed.dropFirst(fenceLen))
                    let isCloser = fenceLen >= codeBlockFenceLen && afterFence.trimmingCharacters(in: .whitespaces).isEmpty
                    if isCloser {
                        let fullRange = NSRange(location: codeBlockStart, length: NSMaxRange(lineRange) - codeBlockStart)
                        let raw = nsText.substring(with: fullRange)
                        slots.append(.block(EditorBlock(
                            id: UUID(), kind: .codeBlock(language: codeBlockLanguage),
                            sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                            contentRange: fullRange
                        )))
                        inCodeBlock = false
                        cursor = NSMaxRange(lineRange)
                        continue
                    }
                } else {
                    inCodeBlock = true
                    codeBlockStart = lineRange.location
                    codeBlockFenceLen = fenceLen
                    let lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
                    codeBlockLanguage = lang.isEmpty ? nil : lang
                    cursor = NSMaxRange(lineRange)
                    continue
                }
            }

            if inCodeBlock {
                cursor = NSMaxRange(lineRange)
                continue
            }

            let pipeCount = trimmed.filter { $0 == "|" }.count
            let isTableLine = trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
            var tableConfirmed = inTable && isTableLine
            if isTableLine && !inTable {
                if pipeCount >= 3 {
                    tableConfirmed = true
                } else {
                    let next = NSMaxRange(lineRange)
                    if next < nsText.length {
                        let nextRange = nsText.lineRange(for: NSRange(location: next, length: 0))
                        let nextTrimmed = nsText.substring(with: nextRange).trimmingCharacters(in: .newlines)
                        let separatorChars = Set<Character>("|-:= \t")
                        let looksLikeSeparator = nextTrimmed.hasPrefix("|") && nextTrimmed.hasSuffix("|") && nextTrimmed.contains("-") && nextTrimmed.allSatisfy { separatorChars.contains($0) }
                        if looksLikeSeparator {
                            tableConfirmed = true
                        }
                    }
                }
            }

            if tableConfirmed {
                if !inTable {
                    inTable = true
                    tableStart = lineRange.location
                }
                cursor = NSMaxRange(lineRange)
                continue
            }

            let toggleSearchRange = NSRange(location: 0, length: (trimmed as NSString).length)
            if let toggleMatch = toggleRegex.firstMatch(in: trimmed, range: toggleSearchRange) {
                let stateStr = toggleMatch.range(at: 1).location != NSNotFound
                    ? (trimmed as NSString).substring(with: toggleMatch.range(at: 1)) : ">"
                let expanded = stateStr == "v"
                let toggleStart = lineRange.location
                cursor = NSMaxRange(lineRange)
                while cursor < nsText.length {
                    let nextLineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
                    let nextLine = nsText.substring(with: nextLineRange).trimmingCharacters(in: .newlines)
                    if nextLine.hasPrefix(">> ") || nextLine == ">>" {
                        cursor = NSMaxRange(nextLineRange)
                    } else {
                        break
                    }
                }
                let fullRange = NSRange(location: toggleStart, length: cursor - toggleStart)
                let raw = nsText.substring(with: fullRange)
                let headerEnd = NSMaxRange(lineRange) - toggleStart
                let contentRange = NSRange(location: toggleStart + headerEnd, length: max(0, fullRange.length - headerEnd))
                slots.append(.block(EditorBlock(
                    id: UUID(), kind: .toggle(expanded: expanded),
                    sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                    contentRange: contentRange
                )))
                continue
            }

            let calloutSearchRange = NSRange(location: 0, length: (trimmed as NSString).length)
            if let calloutMatch = calloutRegex.firstMatch(in: trimmed, range: calloutSearchRange) {
                let typeStr = calloutMatch.range(at: 1).location != NSNotFound
                    ? (trimmed as NSString).substring(with: calloutMatch.range(at: 1)).lowercased() : "note"
                let titleStr = calloutMatch.range(at: 2).location != NSNotFound
                    ? (trimmed as NSString).substring(with: calloutMatch.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
                let calloutType = CalloutType(rawValue: typeStr) ?? .note
                let title: String? = titleStr.isEmpty ? nil : titleStr
                let calloutStart = lineRange.location
                cursor = NSMaxRange(lineRange)
                while cursor < nsText.length {
                    let nextLineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
                    let nextLine = nsText.substring(with: nextLineRange).trimmingCharacters(in: .newlines)
                    if nextLine.hasPrefix("> ") || nextLine == ">" {
                        cursor = NSMaxRange(nextLineRange)
                    } else {
                        break
                    }
                }
                let fullRange = NSRange(location: calloutStart, length: cursor - calloutStart)
                let raw = nsText.substring(with: fullRange)
                let headerEnd = NSMaxRange(lineRange) - calloutStart
                let contentRange = NSRange(location: calloutStart + headerEnd, length: max(0, fullRange.length - headerEnd))
                slots.append(.block(EditorBlock(
                    id: UUID(), kind: .callout(type: calloutType, title: title),
                    sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                    contentRange: contentRange
                )))
                continue
            }

            // Defer per-line parse to the parallel phase.
            slots.append(.line(lineRange))
            cursor = NSMaxRange(lineRange)
        }

        if inMathBlock {
            let fullRange = NSRange(location: mathBlockStart, length: nsText.length - mathBlockStart)
            let raw = nsText.substring(with: fullRange)
            slots.append(.block(EditorBlock(
                id: UUID(), kind: .mathBlock,
                sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                contentRange: fullRange
            )))
        }

        if inCodeBlock {
            let fullRange = NSRange(location: codeBlockStart, length: nsText.length - codeBlockStart)
            let raw = nsText.substring(with: fullRange)
            slots.append(.block(EditorBlock(
                id: UUID(), kind: .codeBlock(language: codeBlockLanguage),
                sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                contentRange: fullRange
            )))
        }

        if inTable {
            let fullRange = NSRange(location: tableStart, length: nsText.length - tableStart)
            let raw = nsText.substring(with: fullRange)
            slots.append(.block(EditorBlock(
                id: UUID(), kind: .table,
                sourceRange: fullRange, rawText: raw, indent: "", prefix: "",
                contentRange: fullRange
            )))
        }

        // === Pass 2: parallel per-line block parse ===
        var lineRanges: [NSRange] = []
        lineRanges.reserveCapacity(slots.count)
        for slot in slots {
            if case .line(let r) = slot {
                lineRanges.append(r)
            }
        }

        var parsedLines = [EditorBlock?](repeating: nil, count: lineRanges.count)
        let blockParallelThreshold = 256
        if lineRanges.count >= blockParallelThreshold {
            parsedLines.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: lineRanges.count) { idx in
                    let r = lineRanges[idx]
                    let text = nsText.substring(with: r)
                    buffer[idx] = parseLine(lineRange: r, lineText: text)
                }
            }
        } else {
            for idx in 0..<lineRanges.count {
                let r = lineRanges[idx]
                let text = nsText.substring(with: r)
                parsedLines[idx] = parseLine(lineRange: r, lineText: text)
            }
        }

        // === Pass 3: flatten slots in order ===
        var blocks: [EditorBlock] = []
        blocks.reserveCapacity(slots.count)
        var lineCursor = 0
        for slot in slots {
            switch slot {
            case .line:
                if let block = parsedLines[lineCursor] {
                    blocks.append(block)
                }
                lineCursor += 1
            case .block(let b):
                blocks.append(b)
            }
        }

        assignDepths(&blocks)

        // === Pass 4: parallel inline parse ===
        var eligibleIndices: [Int] = []
        eligibleIndices.reserveCapacity(blocks.count)
        var eligibleContents: [String] = []
        eligibleContents.reserveCapacity(blocks.count)
        for i in 0..<blocks.count {
            switch blocks[i].kind {
            case .codeBlock, .table, .image, .horizontalRule, .callout, .toggle, .mathBlock:
                continue
            default:
                eligibleIndices.append(i)
                eligibleContents.append(blocks[i].content)
            }
        }

        var inlineResults = [(String, [InlineSpan])?](repeating: nil, count: eligibleIndices.count)
        let inlineParallelThreshold = 8
        if eligibleIndices.count >= inlineParallelThreshold {
            inlineResults.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: eligibleIndices.count) { idx in
                    let raw = eligibleContents[idx]
                    buffer[idx] = InlineParser.parse(raw)
                }
            }
        } else {
            for idx in 0..<eligibleIndices.count {
                inlineResults[idx] = InlineParser.parse(eligibleContents[idx])
            }
        }

        for (idx, result) in inlineResults.enumerated() {
            guard let (clean, spans) = result else { continue }
            let blockIndex = eligibleIndices[idx]
            blocks[blockIndex].cleanContent = clean
            blocks[blockIndex].spans = spans
        }

        return BlockDocument(blocks: blocks, source: markdown)
    }

    static func assignDepths(_ blocks: inout [EditorBlock]) {
        assignTreeStructure(&blocks)
    }

    static func assignTreeStructure(_ blocks: inout [EditorBlock]) {
        for i in 0..<blocks.count {
            switch blocks[i].kind {
            case .bulletItem, .orderedItem, .checkboxItem:
                let raw = BlockTreeNavigator.depthFromIndent(blocks[i].indent)
                if i > 0 {
                    let prevIsListItem: Bool
                    switch blocks[i - 1].kind {
                    case .bulletItem, .orderedItem, .checkboxItem: prevIsListItem = true
                    default: prevIsListItem = false
                    }
                    if prevIsListItem {
                        let maxAllowed = blocks[i - 1].depth + 1
                        blocks[i].depth = min(raw, maxAllowed)
                    } else {
                        blocks[i].depth = raw
                    }
                } else {
                    blocks[i].depth = raw
                }
            case .blockquote:
                let markers = blocks[i].prefix.filter { $0 == ">" }.count
                blocks[i].depth = max(0, markers - 1)
            default:
                blocks[i].depth = 0
            }
        }

        // O(N) parent assignment via per-kind depth stacks.
        // Each block is pushed once and popped at most once; lookup at d-1 is O(1).
        // Stacks reset when the contiguous run of that kind breaks, matching the
        // prior O(N²) backward-scan behavior (which terminated at non-list / non-quote
        // blocks). Stack is padded with nils on depth jumps for safety, though the
        // depth-clamp pass above prevents jumps when the prior block is the same kind.
        var listStack: [UUID?] = []
        var quoteStack: [UUID?] = []
        var lastWasList = false
        var lastWasQuote = false

        for i in 0..<blocks.count {
            let d = blocks[i].depth
            switch blocks[i].kind {
            case .bulletItem, .orderedItem, .checkboxItem:
                if !lastWasList { listStack.removeAll(keepingCapacity: true) }
                while listStack.count > d { listStack.removeLast() }
                blocks[i].parentId = (d > 0 && d - 1 < listStack.count) ? listStack[d - 1] : nil
                while listStack.count < d { listStack.append(nil) }
                listStack.append(blocks[i].id)
                lastWasList = true
                lastWasQuote = false
            case .blockquote:
                if !lastWasQuote { quoteStack.removeAll(keepingCapacity: true) }
                while quoteStack.count > d { quoteStack.removeLast() }
                blocks[i].parentId = (d > 0 && d - 1 < quoteStack.count) ? quoteStack[d - 1] : nil
                while quoteStack.count < d { quoteStack.append(nil) }
                quoteStack.append(blocks[i].id)
                lastWasList = false
                lastWasQuote = true
            default:
                blocks[i].parentId = nil
                lastWasList = false
                lastWasQuote = false
            }
        }
    }

    private static func parseLine(lineRange: NSRange, lineText: String) -> EditorBlock? {
        let lineNS = lineText as NSString
        let searchRange = NSRange(location: 0, length: lineNS.length)

        if let match = headingRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let hashRange = match.range(at: 2)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let level = hashRange.length
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))
            return EditorBlock(id: UUID(), kind: .heading(level: level), sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        if let match = blockquoteRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))

            // Recurse: a blockquote line whose content is itself a list/checkbox
            // (`> - item`, `> 1. [ ] task`) becomes the inner kind with the
            // outer `> ` preserved in the prefix and the insideBlockquote flag set.
            let afterQuote = NSRange(location: prefixEnd, length: lineNS.length - prefixEnd)
            if afterQuote.length > 0 {
                let innerText = lineNS.substring(with: afterQuote)
                let innerLineRange = NSRange(location: lineRange.location + prefixEnd, length: lineRange.length - prefixEnd)
                if let inner = parseLine(lineRange: innerLineRange, lineText: innerText) {
                    switch inner.kind {
                    case .bulletItem, .orderedItem, .checkboxItem:
                        var hybrid = inner
                        hybrid.rawText = lineText
                        hybrid.sourceRange = lineRange
                        hybrid.indent = indent
                        hybrid.prefix = prefix + inner.prefix
                        hybrid.contentRange = NSRange(location: inner.contentRange.location, length: inner.contentRange.length)
                        hybrid.insideBlockquote = true
                        return hybrid
                    default:
                        break
                    }
                }
            }

            return EditorBlock(id: UUID(), kind: .blockquote, sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        if let match = checkboxRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let markerRange = match.range(at: 2)
            let checkedRange = match.range(at: 3)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let marker = markerRange.location != NSNotFound ? lineNS.substring(with: markerRange) : "-"
            let checked = checkedRange.location != NSNotFound && lineNS.substring(with: checkedRange) != " "
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))
            return EditorBlock(id: UUID(), kind: .checkboxItem(checked: checked, marker: marker), sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        // Ordered checkbox: `1. [ ] text` / `2. [x] text`. Stored as checkboxItem
        // but with marker = "1." (ordered prefix) so render and round-trip show
        // both the number and the checkbox.
        if let match = orderedCheckboxRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let numberRange = match.range(at: 2)
            let checkedRange = match.range(at: 3)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let number = numberRange.location != NSNotFound ? lineNS.substring(with: numberRange) : "1"
            let marker = "\(number)."
            let checked = checkedRange.location != NSNotFound && lineNS.substring(with: checkedRange) != " "
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))
            return EditorBlock(id: UUID(), kind: .checkboxItem(checked: checked, marker: marker), sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        if let match = bulletRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let markerRange = match.range(at: 2)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let marker = markerRange.location != NSNotFound ? lineNS.substring(with: markerRange) : "-"
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))
            return EditorBlock(id: UUID(), kind: .bulletItem(marker: marker), sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        if let match = orderedRegex.firstMatch(in: lineText, range: searchRange) {
            let indentRange = match.range(at: 1)
            let numberRange = match.range(at: 2)
            let indent = indentRange.length > 0 ? lineNS.substring(with: indentRange) : ""
            let number = numberRange.location != NSNotFound ? Int(lineNS.substring(with: numberRange)) ?? 1 : 1
            let prefixEnd = NSMaxRange(match.range)
            let prefix = lineNS.substring(to: prefixEnd)
            let contentRange = NSRange(location: lineRange.location + prefixEnd, length: max(0, lineRange.length - prefixEnd))
            return EditorBlock(id: UUID(), kind: .orderedItem(number: number), sourceRange: lineRange, rawText: lineText, indent: indent, prefix: prefix, contentRange: contentRange)
        }

        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isHorizontalRule(trimmed) {
            return EditorBlock(id: UUID(), kind: .horizontalRule, sourceRange: lineRange, rawText: lineText, indent: "", prefix: lineText, contentRange: NSRange(location: NSMaxRange(lineRange), length: 0))
        }

        if let imgMatch = imageRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
            let alt = imgMatch.range(at: 1).location != NSNotFound ? (trimmed as NSString).substring(with: imgMatch.range(at: 1)) : ""
            let url = imgMatch.range(at: 2).location != NSNotFound ? (trimmed as NSString).substring(with: imgMatch.range(at: 2)) : ""
            return EditorBlock(id: UUID(), kind: .image(alt: alt, url: url), sourceRange: lineRange, rawText: lineText, indent: "", prefix: "", contentRange: lineRange)
        }

        if trimmed.isEmpty {
            return EditorBlock(id: UUID(), kind: .empty, sourceRange: lineRange, rawText: lineText, indent: "", prefix: "", contentRange: lineRange)
        }

        return EditorBlock(id: UUID(), kind: .paragraph, sourceRange: lineRange, rawText: lineText, indent: "", prefix: "", contentRange: lineRange)
    }

    static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed.filter { !$0.isWhitespace })
        return chars.count == 1 && (chars.first == "-" || chars.first == "*" || chars.first == "_")
    }

    static func mergeIdentity(old: BlockDocument, new: BlockDocument) -> BlockDocument {
        var result = new
        guard !old.blocks.isEmpty else { return result }

        let maxLookahead = 6
        var consumed = Set<Int>()
        var matched = Set<Int>()

        // Hash by prefix+length (cheap) instead of full rawText (O(N) per block).
        // Equality on collision falls back to full-string compare — correct.
        var rawIndex: [RawKey: [Int]] = [:]
        for j in 0..<old.blocks.count {
            rawIndex[RawKey(old.blocks[j].rawText), default: []].append(j)
        }

        for i in 0..<result.blocks.count {
            let key = RawKey(result.blocks[i].rawText)
            guard var candidates = rawIndex[key] else { continue }
            while let first = candidates.first {
                candidates.removeFirst()
                if consumed.contains(first) { continue }
                result.blocks[i].id = old.blocks[first].id
                result.blocks[i].collapsed = old.blocks[first].collapsed
                consumed.insert(first)
                matched.insert(i)
                rawIndex[key] = candidates
                break
            }
        }

        for i in 0..<result.blocks.count where !matched.contains(i) {
            let searchStart = max(0, i - maxLookahead)
            let searchEnd = min(old.blocks.count, i + maxLookahead)
            var bestJ = -1
            var bestSim = 0.6

            for j in searchStart..<searchEnd where !consumed.contains(j) {
                if old.blocks[j].kind == result.blocks[i].kind {
                    let sim = wordSimilarity(old.blocks[j].rawText, result.blocks[i].rawText)
                    if sim > bestSim {
                        bestSim = sim
                        bestJ = j
                    }
                }
            }

            if bestJ >= 0 {
                result.blocks[i].id = old.blocks[bestJ].id
                result.blocks[i].collapsed = old.blocks[bestJ].collapsed
                consumed.insert(bestJ)
                matched.insert(i)
            }
        }

        return result
    }

    private static func wordSimilarity(_ a: String, _ b: String) -> Double {
        let normalize: (String) -> Set<String> = { text in
            Set(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
                .map { $0.lowercased() }
                .filter { !$0.isEmpty })
        }
        let wordsA = normalize(a)
        let wordsB = normalize(b)
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        let union = wordsA.union(wordsB).count
        guard union > 0 else { return 1.0 }
        return Double(wordsA.intersection(wordsB).count) / Double(union)
    }

    static func renumberOrderedRuns(_ blocks: inout [EditorBlock]) {
        var i = 0
        while i < blocks.count {
            guard case .orderedItem = blocks[i].kind else { i += 1; continue }
            var number = 1
            while i < blocks.count, case .orderedItem = blocks[i].kind {
                let oldRaw = blocks[i].rawText as NSString
                if let match = orderedRegex.firstMatch(in: blocks[i].rawText, range: NSRange(location: 0, length: oldRaw.length)) {
                    let numberRange = match.range(at: 2)
                    if numberRange.location != NSNotFound {
                        let oldNumber = oldRaw.substring(with: numberRange)
                        let newNumber = "\(number)"
                        if oldNumber != newNumber {
                            let mutable = NSMutableString(string: blocks[i].rawText)
                            mutable.replaceCharacters(in: numberRange, with: newNumber)
                            blocks[i].rawText = mutable as String
                            let prefixMutable = NSMutableString(string: blocks[i].prefix)
                            if let prefixMatch = orderedRegex.firstMatch(in: blocks[i].prefix, range: NSRange(location: 0, length: (blocks[i].prefix as NSString).length)) {
                                let prefixNumRange = prefixMatch.range(at: 2)
                                if prefixNumRange.location != NSNotFound {
                                    prefixMutable.replaceCharacters(in: prefixNumRange, with: newNumber)
                                    blocks[i].prefix = prefixMutable as String
                                }
                            }
                            let delta = (newNumber as NSString).length - (oldNumber as NSString).length
                            blocks[i].sourceRange = NSRange(location: blocks[i].sourceRange.location, length: blocks[i].sourceRange.length + delta)
                            blocks[i].contentRange = NSRange(location: blocks[i].contentRange.location + delta, length: blocks[i].contentRange.length)
                        }
                        blocks[i].kind = .orderedItem(number: number)
                    }
                }
                number += 1
                i += 1
            }
        }
    }
}
