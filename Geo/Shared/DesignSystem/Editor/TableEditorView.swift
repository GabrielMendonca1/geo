import SwiftUI

struct TableCellID: Hashable {
    let row: Int
    let column: Int
}

struct TableEditorView: View {
    @Binding var table: TableModel
    let fontSize: CGFloat
    let onChanged: () -> Void

    @FocusState private var focusedCell: TableCellID?
    @State private var hoveredColumn: Int?
    @State private var hoveredRow: Int?
    @State private var isHovered = false

    private let minCellWidth: CGFloat = 80
    private let maxCellWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            ForEach(0..<table.rowCount, id: \.self) { rowIndex in
                dataRow(rowIndex)
            }
            if isHovered {
                addRowButton
            }
        }
        .background(Palette.secondaryBackground.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Palette.border.opacity(0.3), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { col in
                headerCell(col)
                if col < table.columnCount - 1 {
                    cellDivider
                }
            }
            if isHovered {
                addColumnButton
            }
        }
        .background(Palette.accent.opacity(0.08))
    }

    private func headerCell(_ col: Int) -> some View {
        let cellId = TableCellID(row: -1, column: col)
        return TextField("", text: Binding(
            get: { col < table.headers.count ? table.headers[col] : "" },
            set: { newValue in
                table.updateHeader(column: col, value: newValue)
                onChanged()
            }
        ))
        .textFieldStyle(.plain)
        .font(FontManager.geistMonoFont(size: fontSize, weight: .medium))
        .foregroundColor(Color(Palette.editorForeground))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: minCellWidth, maxWidth: maxCellWidth, alignment: cellAlignment(col))
        .background(focusedCell == cellId ? Palette.accent.opacity(0.06) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(focusedCell == cellId ? Palette.accent : Color.clear, lineWidth: 2)
        )
        .focused($focusedCell, equals: cellId)
        .onSubmit { moveCellDown(from: cellId) }
        .onKeyPress(.escape) { focusedCell = nil; return .handled }
        .onKeyPress(.upArrow) { moveCellUp(from: cellId); return .handled }
        .onKeyPress(.downArrow) { moveCellDown(from: cellId); return .handled }
        .contextMenu { cellContextMenu(row: -1, col: col) }
    }

    private func dataRow(_ rowIndex: Int) -> some View {
        VStack(spacing: 0) {
            rowDivider
            HStack(spacing: 0) {
                ForEach(0..<table.columnCount, id: \.self) { col in
                    dataCell(row: rowIndex, col: col)
                    if col < table.columnCount - 1 {
                        cellDivider
                    }
                }
                if isHovered {
                    Color.clear.frame(width: 28)
                }
            }
        }
        .onHover { hov in hoveredRow = hov ? rowIndex : nil }
    }

    private func dataCell(row: Int, col: Int) -> some View {
        let cellId = TableCellID(row: row, column: col)
        return TextField("", text: Binding(
            get: {
                guard row < table.rows.count, col < table.rows[row].count else { return "" }
                return table.rows[row][col]
            },
            set: { newValue in
                table.updateCell(row: row, column: col, value: newValue)
                onChanged()
            }
        ))
        .textFieldStyle(.plain)
        .font(FontManager.geistMonoFont(size: fontSize))
        .foregroundColor(Color(Palette.editorForeground))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: minCellWidth, maxWidth: maxCellWidth, alignment: cellAlignment(col))
        .background(focusedCell == cellId ? Palette.accent.opacity(0.06) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(focusedCell == cellId ? Palette.accent : Color.clear, lineWidth: 2)
        )
        .focused($focusedCell, equals: cellId)
        .onSubmit { moveCellDown(from: cellId) }
        .onKeyPress(.escape) { focusedCell = nil; return .handled }
        .onKeyPress(.upArrow) { moveCellUp(from: cellId); return .handled }
        .onKeyPress(.downArrow) { moveCellDown(from: cellId); return .handled }
        .contextMenu { cellContextMenu(row: row, col: col) }
    }

    private func cellAlignment(_ col: Int) -> Alignment {
        guard col < table.columnAlignments.count else { return .leading }
        switch table.columnAlignments[col] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Palette.foreground.opacity(0.10))
            .frame(width: 1)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Palette.foreground.opacity(0.10))
            .frame(height: 1)
    }

    private var addColumnButton: some View {
        Button {
            table.addColumn(header: "")
            onChanged()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Palette.tertiaryForeground)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var addRowButton: some View {
        VStack(spacing: 0) {
            rowDivider
            Button {
                table.addRow()
                onChanged()
            } label: {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.tertiaryForeground)
                    Text("New row")
                        .font(.system(size: fontSize * 0.85))
                        .foregroundColor(Palette.tertiaryForeground)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity)
    }

    private func handleTab(from cell: TableCellID, shift: Bool) -> KeyPress.Result {
        if shift {
            moveCellPrevious(from: cell)
        } else {
            moveCellNext(from: cell)
        }
        return .handled
    }

    private func moveCellNext(from cell: TableCellID) {
        let nextCol = cell.column + 1
        if nextCol < table.columnCount {
            focusedCell = TableCellID(row: cell.row, column: nextCol)
        } else {
            let nextRow = cell.row + 1
            if nextRow < table.rowCount {
                focusedCell = TableCellID(row: nextRow, column: 0)
            } else {
                table.addRow()
                onChanged()
                DispatchQueue.main.async {
                    focusedCell = TableCellID(row: table.rowCount - 1, column: 0)
                }
            }
        }
    }

    private func moveCellPrevious(from cell: TableCellID) {
        let prevCol = cell.column - 1
        if prevCol >= 0 {
            focusedCell = TableCellID(row: cell.row, column: prevCol)
        } else {
            let prevRow = cell.row - 1
            if prevRow >= -1 {
                focusedCell = TableCellID(row: prevRow, column: table.columnCount - 1)
            }
        }
    }

    private func moveCellDown(from cell: TableCellID) {
        let nextRow = cell.row + 1
        if nextRow < table.rowCount {
            focusedCell = TableCellID(row: nextRow, column: cell.column)
        } else {
            table.addRow()
            onChanged()
            DispatchQueue.main.async {
                focusedCell = TableCellID(row: table.rowCount - 1, column: cell.column)
            }
        }
    }

    private func moveCellUp(from cell: TableCellID) {
        let prevRow = cell.row - 1
        if prevRow >= -1 {
            focusedCell = TableCellID(row: prevRow, column: cell.column)
        }
    }

    @ViewBuilder
    private func cellContextMenu(row: Int, col: Int) -> some View {
        if row >= 0 {
            Button("Insert Row Above") {
                table.addRow(at: row)
                onChanged()
            }
            Button("Insert Row Below") {
                table.addRow(at: row + 1)
                onChanged()
            }
        } else {
            Button("Insert Row Below") {
                table.addRow(at: 0)
                onChanged()
            }
        }
        Divider()
        Button("Insert Column Left") {
            table.addColumn(at: col, header: "")
            onChanged()
        }
        Button("Insert Column Right") {
            table.addColumn(at: col + 1, header: "")
            onChanged()
        }
        Divider()
        if row >= 0 && table.rowCount > 0 {
            Button("Delete Row") {
                table.removeRow(at: row)
                onChanged()
            }
        }
        if table.columnCount > 1 {
            Button("Delete Column") {
                table.removeColumn(at: col)
                onChanged()
            }
        }
        Divider()
        Menu("Alignment") {
            Button("Left") {
                table.columnAlignments[col] = .left
                onChanged()
            }
            Button("Center") {
                table.columnAlignments[col] = .center
                onChanged()
            }
            Button("Right") {
                table.columnAlignments[col] = .right
                onChanged()
            }
        }
    }
}
