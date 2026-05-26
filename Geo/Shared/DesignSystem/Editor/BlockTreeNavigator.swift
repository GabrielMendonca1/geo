import Foundation

enum BlockTreeNavigator {

    static func depthFromIndent(_ indent: String) -> Int {
        let tabs = indent.filter { $0 == "\t" }.count
        let spaces = indent.filter { $0 == " " }.count
        return tabs + spaces / 2
    }

    static func visibleBlocks(_ blocks: [EditorBlock]) -> [Int] {
        var result: [Int] = []
        var collapseBelow: Int?
        for i in 0..<blocks.count {
            if let cap = collapseBelow, blocks[i].depth > cap { continue }
            collapseBelow = nil
            result.append(i)
            if blocks[i].collapsed { collapseBelow = blocks[i].depth }
        }
        return result
    }

    static func hasChildren(_ index: Int, in blocks: [EditorBlock]) -> Bool {
        guard index >= 0, index < blocks.count else { return false }
        let parentId = blocks[index].id
        for i in 0..<blocks.count where i != index {
            if blocks[i].parentId == parentId { return true }
        }
        return false
    }

    static func subtreeRange(of index: Int, in blocks: [EditorBlock]) -> Range<Int> {
        guard index >= 0, index < blocks.count else { return index..<index }
        let rootId = blocks[index].id
        var descendantIds: Set<UUID> = [rootId]
        var end = index + 1
        while end < blocks.count {
            if let pid = blocks[end].parentId, descendantIds.contains(pid) {
                descendantIds.insert(blocks[end].id)
                end += 1
            } else {
                break
            }
        }
        return index..<end
    }

    static func siblings(of index: Int, in blocks: [EditorBlock]) -> [Int] {
        guard index >= 0, index < blocks.count else { return [] }
        let pid = blocks[index].parentId
        var result: [Int] = []
        for i in 0..<blocks.count {
            if blocks[i].parentId == pid { result.append(i) }
        }
        return result
    }

    static func parent(of index: Int, in blocks: [EditorBlock]) -> Int? {
        guard index >= 0, index < blocks.count else { return nil }
        guard let pid = blocks[index].parentId else { return nil }
        for i in 0..<blocks.count where blocks[i].id == pid {
            return i
        }
        return nil
    }
}
