import Foundation
import Observation
import CryptoKit

@Observable
final class BlockEditorDocument {
    var blocks: [EditorBlock] = []
    var focusRequest: BlockFocusRequest?
    var editGeneration: UInt64 = 0
    private(set) var lastEditedBlockId: UUID?
    private(set) var blockIndex: [UUID: Int] = [:]
    private var hiddenFrontmatter: String = ""

    @ObservationIgnored
    var onDirty: (() -> Void)?

    init(markdown: String) {
        let split = Self.splitHiddenMetadata(markdown)
        hiddenFrontmatter = split.hidden
        let doc = MarkdownBlockParser.parse(markdown: split.body)
        var parsed = doc.blocks
        Self.restoreIds(&parsed, using: split.idPairs)
        self.blocks = parsed
        rebuildBlockIndex()
    }

    init(blocks: [EditorBlock]) {
        var seeded = blocks
        MarkdownBlockParser.assignDepths(&seeded)
        self.blocks = seeded
        rebuildBlockIndex()
    }

    func loadMarkdown(_ markdown: String) {
        let split = Self.splitHiddenMetadata(markdown)
        hiddenFrontmatter = split.hidden
        let newDoc = MarkdownBlockParser.parse(markdown: split.body)
        var restored = newDoc.blocks
        Self.restoreIds(&restored, using: split.idPairs)
        let oldDoc = BlockDocument(blocks: blocks, source: "")
        let restoredDoc = BlockDocument(blocks: restored, source: newDoc.source)
        blocks = MarkdownBlockParser.mergeIdentity(old: oldDoc, new: restoredDoc).blocks
        editGeneration &+= 1
        rebuildBlockIndex()
    }

    func index(of id: UUID) -> Int? { blockIndex[id] }

    @discardableResult
    func seedEmptyParagraphIfNeeded() -> UUID? {
        guard blocks.isEmpty else { return nil }
        let paragraph = EditorBlock.paragraph(content: "")
        blocks = [paragraph]
        rebuildBlockIndex()
        return paragraph.id
    }

    private func rebuildBlockIndex() {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(blocks.count)
        for (i, b) in blocks.enumerated() { map[b.id] = i }
        blockIndex = map
    }

    func serialize() -> String {
        var pairs: [(String, UUID)] = []
        pairs.reserveCapacity(blocks.count)
        for b in blocks {
            pairs.append((Self.fingerprint(for: b.rawText), b.id))
        }
        let frontmatter = Self.emitFrontmatter(existing: hiddenFrontmatter, idPairs: pairs)
        return frontmatter + blocks.map(\.rawText).joined()
    }

    private static func fingerprint(for rawText: String) -> String {
        let digest = SHA256.hash(data: Data(rawText.utf8))
        let bytes = Array(digest).prefix(6)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func restoreIds(_ blocks: inout [EditorBlock], using pairs: [(String, UUID)]) {
        guard !pairs.isEmpty else { return }
        var queues: [String: [UUID]] = [:]
        for (fp, uuid) in pairs {
            queues[fp, default: []].append(uuid)
        }
        var idRewrite: [UUID: UUID] = [:]
        for i in blocks.indices {
            let fp = Self.fingerprint(for: blocks[i].rawText)
            guard var q = queues[fp], !q.isEmpty else { continue }
            let persistedId = q.removeFirst()
            queues[fp] = q
            idRewrite[blocks[i].id] = persistedId
            blocks[i].id = persistedId
        }
        guard !idRewrite.isEmpty else { return }
        for i in blocks.indices {
            if let pid = blocks[i].parentId, let newPid = idRewrite[pid] {
                blocks[i].parentId = newPid
            }
        }
    }

    private static func emitFrontmatter(existing: String, idPairs: [(String, UUID)]) -> String {
        let stripped = stripGeoBlockIdsBlock(from: existing)
        let mapLines = buildGeoBlockIdsLines(idPairs: idPairs)

        if stripped.isEmpty {
            // No pre-existing frontmatter: don't synthesize one just to persist
            // ids. Hygiene over pollution — ids stay in-memory until the user
            // adds frontmatter (e.g. via `type:` metadata) on their terms.
            return ""
        }

        if idPairs.isEmpty {
            return stripped
        }

        let ns = stripped as NSString
        let trailingNewlines: String
        var trimmedEnd = ns.length
        while trimmedEnd > 0, ns.character(at: trimmedEnd - 1) == 0x0A {
            trimmedEnd -= 1
        }
        trailingNewlines = ns.substring(from: trimmedEnd)
        let core = ns.substring(with: NSRange(location: 0, length: trimmedEnd))

        guard core.hasSuffix("---") else {
            return stripped
        }

        let coreNoEnd = String(core.dropLast(3))
        let withInsertion = coreNoEnd + "geo_block_ids:\n" + mapLines + "---" + (trailingNewlines.isEmpty ? "\n" : trailingNewlines)
        return withInsertion
    }

    private static func buildGeoBlockIdsLines(idPairs: [(String, UUID)]) -> String {
        guard !idPairs.isEmpty else { return "" }
        var out = ""
        for (fp, uuid) in idPairs {
            out += "  - \(fp) \(uuid.uuidString)\n"
        }
        return out
    }

    private static func stripGeoBlockIdsBlock(from frontmatter: String) -> String {
        guard !frontmatter.isEmpty else { return frontmatter }
        let lines = frontmatter.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line == "geo_block_ids:" {
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if next.hasPrefix("  ") {
                        i += 1
                        continue
                    }
                    break
                }
                continue
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func splitHiddenMetadata(_ markdown: String) -> (hidden: String, body: String, idPairs: [(String, UUID)]) {
        let split = splitFrontmatter(markdown)
        let cleaned = stripLegacySymphonyBodyMetadata(split.body)
        let idPairs = parseGeoBlockIds(from: split.frontmatter)
        return (split.frontmatter, cleaned, idPairs)
    }

    private static func parseGeoBlockIds(from frontmatter: String) -> [(String, UUID)] {
        guard !frontmatter.isEmpty else { return [] }
        let lines = frontmatter.components(separatedBy: "\n")
        var pairs: [(String, UUID)] = []
        var i = 0
        while i < lines.count {
            if lines[i] == "geo_block_ids:" {
                i += 1
                while i < lines.count {
                    let line = lines[i]
                    if line == "---" || (!line.hasPrefix("  ")) {
                        break
                    }
                    // New list-of-pairs format: "  - <12hex> <uuid>"
                    if line.hasPrefix("  - ") {
                        let entry = String(line.dropFirst(4))
                        let parts = entry.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                        if parts.count == 2 {
                            let key = String(parts[0])
                            let value = String(parts[1])
                            if key.count == 12,
                               key.allSatisfy({ $0.isHexDigit }),
                               let uuid = UUID(uuidString: value) {
                                pairs.append((key, uuid))
                            }
                        }
                    } else {
                        // Backward-compat: old "  <hex>: <uuid>" format
                        let entry = String(line.dropFirst(2))
                        if let colon = entry.firstIndex(of: ":") {
                            let key = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
                            let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                            if key.count == 12,
                               key.allSatisfy({ $0.isHexDigit }),
                               let uuid = UUID(uuidString: value) {
                                pairs.append((key, uuid))
                            }
                        }
                    }
                    i += 1
                }
                continue
            }
            i += 1
        }
        return pairs
    }

    private static func splitFrontmatter(_ markdown: String) -> (frontmatter: String, body: String) {
        let ns = markdown as NSString
        guard ns.length >= 3 else { return ("", markdown) }
        var cursor = 0
        let firstLineRange = ns.lineRange(for: NSRange(location: 0, length: 0))
        let firstLine = ns.substring(with: firstLineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == "---" else { return ("", markdown) }
        cursor = NSMaxRange(firstLineRange)
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = NSMaxRange(lineRange)
            if line == "---" {
                let prefix = ns.substring(with: NSRange(location: 0, length: cursor))
                let body = ns.substring(from: cursor)
                return (prefix, body)
            }
        }
        return ("", markdown)
    }

    private static func stripLegacySymphonyBodyMetadata(_ markdown: String) -> String {
        guard markdown.contains("[[Symphony]] #symphony") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "[[Symphony]] #symphony" else { return false }
            guard !trimmed.hasPrefix("State:") else { return false }
            return true
        }
        return filtered.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    func updateBlockContent(at index: Int, content: String, spans: [InlineSpan]) {
        guard index >= 0, index < blocks.count else { return }
        let block = blocks[index]
        if case .codeBlock = block.kind {
            blocks[index] = block.withCodeContent(content)
        } else if case .mathBlock = block.kind {
            blocks[index] = block.withMathContent(content)
        } else {
            blocks[index] = block.withContent(content, spans: spans)
        }
        lastEditedBlockId = blocks[index].id
        editGeneration &+= 1
        onDirty?()
    }

    func performStructuralEdit(
        undoManager: UndoManager?,
        name: String,
        newFocus: BlockFocusRequest?,
        _ edit: (inout [EditorBlock]) -> Void
    ) {
        let snapshotBlocks = blocks
        let snapshotFocus = focusRequest

        edit(&blocks)
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        MarkdownBlockParser.assignDepths(&blocks)
        rebuildBlockIndex()
        focusRequest = newFocus
        lastEditedBlockId = nil
        editGeneration &+= 1
        onDirty?()

        undoManager?.registerUndo(withTarget: self) { target in
            target.performStructuralEdit(
                undoManager: undoManager,
                name: name,
                newFocus: snapshotFocus
            ) { b in
                b = snapshotBlocks
            }
        }
        undoManager?.setActionName(name)
    }

    func executeCommand(_ command: EditorCommand, undoManager: UndoManager?) {
        applyExecute(command, undoManager: undoManager)
    }

    private func applyExecute(_ command: EditorCommand, undoManager: UndoManager?) {
        let focus = command.execute(on: &blocks)
        afterStructuralEdit(focus: focus)
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyUndo(command, undoManager: undoManager)
        }
        undoManager?.setActionName(command.name)
    }

    private func applyUndo(_ command: EditorCommand, undoManager: UndoManager?) {
        let focus = command.undo(on: &blocks)
        afterStructuralEdit(focus: focus)
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyExecute(command, undoManager: undoManager)
        }
        undoManager?.setActionName(command.name)
    }

    private func afterStructuralEdit(focus: BlockFocusRequest?) {
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        MarkdownBlockParser.assignDepths(&blocks)
        rebuildBlockIndex()
        focusRequest = focus
        lastEditedBlockId = nil
        editGeneration &+= 1
        onDirty?()
    }
}
