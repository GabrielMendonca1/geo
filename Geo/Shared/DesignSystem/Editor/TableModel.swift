import Foundation

struct TableModel: Equatable, Hashable {
    var headers: [String]
    var rows: [[String]]
    var columnAlignments: [ColumnAlignment]

    enum ColumnAlignment: Equatable, Hashable {
        case left, center, right
    }

    var columnCount: Int { headers.count }
    var rowCount: Int { rows.count }

    static func parse(markdown: String) -> TableModel? {
        let lines = markdown.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }

        let separatorCells = parseCells(lines[1])
        let isSeparator = separatorCells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.allSatisfy({ $0 == "-" || $0 == ":" }) && t.contains("-")
        }
        guard isSeparator else { return nil }

        var alignments: [ColumnAlignment] = []
        for cell in separatorCells {
            let t = cell.trimmingCharacters(in: .whitespaces)
            let startsColon = t.hasPrefix(":")
            let endsColon = t.hasSuffix(":")
            if startsColon && endsColon {
                alignments.append(.center)
            } else if endsColon {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }

        while alignments.count < headers.count { alignments.append(.left) }
        if alignments.count > headers.count { alignments = Array(alignments.prefix(headers.count)) }

        var rows: [[String]] = []
        for i in 2..<lines.count {
            var cells = parseCells(lines[i])
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            rows.append(cells)
        }

        return TableModel(headers: headers, rows: rows, columnAlignments: alignments)
    }

    private static func parseCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func serialize() -> String {
        var lines: [String] = []
        lines.append("| " + headers.joined(separator: " | ") + " |")

        var sepParts: [String] = []
        for alignment in columnAlignments {
            switch alignment {
            case .left: sepParts.append("--------")
            case .center: sepParts.append(":------:")
            case .right: sepParts.append("-------:")
            }
        }
        lines.append("| " + sepParts.joined(separator: " | ") + " |")

        for row in rows {
            var cells = row
            while cells.count < columnCount { cells.append("") }
            lines.append("| " + cells.prefix(columnCount).joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    mutating func addRow(at index: Int? = nil) {
        let newRow = Array(repeating: "", count: columnCount)
        if let index = index {
            rows.insert(newRow, at: min(index, rows.count))
        } else {
            rows.append(newRow)
        }
    }

    mutating func removeRow(at index: Int) {
        guard index >= 0, index < rows.count else { return }
        rows.remove(at: index)
    }

    mutating func addColumn(at index: Int? = nil, header: String = "") {
        if let index = index {
            let safeIndex = min(index, headers.count)
            headers.insert(header, at: safeIndex)
            columnAlignments.insert(.left, at: safeIndex)
            for i in 0..<rows.count {
                rows[i].insert("", at: min(safeIndex, rows[i].count))
            }
        } else {
            headers.append(header)
            columnAlignments.append(.left)
            for i in 0..<rows.count {
                rows[i].append("")
            }
        }
    }

    mutating func removeColumn(at index: Int) {
        guard index >= 0, index < headers.count, headers.count > 1 else { return }
        headers.remove(at: index)
        columnAlignments.remove(at: index)
        for i in 0..<rows.count {
            if index < rows[i].count {
                rows[i].remove(at: index)
            }
        }
    }

    mutating func updateCell(row: Int, column: Int, value: String) {
        guard row >= 0, row < rows.count, column >= 0, column < columnCount else { return }
        while rows[row].count <= column { rows[row].append("") }
        rows[row][column] = value
    }

    mutating func updateHeader(column: Int, value: String) {
        guard column >= 0, column < headers.count else { return }
        headers[column] = value
    }

    static func defaultTable() -> TableModel {
        TableModel(
            headers: ["Column 1", "Column 2", "Column 3"],
            rows: [
                ["", "", ""],
                ["", "", ""]
            ],
            columnAlignments: [.left, .left, .left]
        )
    }
}
