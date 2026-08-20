import Foundation

struct MatrixDot: Equatable {
    let row: Int
    let column: Int
    let x: Double
    let y: Double
}

enum DotMatrix {
    static let rows = 5

    static func triangle(rows: Int = DotMatrix.rows) -> [MatrixDot] {
        guard rows > 1 else { return [MatrixDot(row: 0, column: 0, x: 0.5, y: 0.5)] }
        var dots: [MatrixDot] = []
        let span = Double(rows - 1)
        for row in 0..<rows {
            let count = row + 1
            let y = Double(row) / span
            let width = Double(row) / span
            for column in 0..<count {
                let offset = count == 1 ? 0.5 : Double(column) / Double(count - 1)
                let x = 0.5 + (offset - 0.5) * width
                dots.append(MatrixDot(row: row, column: column, x: x, y: y))
            }
        }
        return dots
    }

    static func steady(_ dots: [MatrixDot]) -> [Double] {
        dots.map { _ in 1 }
    }

    static func level(_ dots: [MatrixDot], level: Float, peak: Float, rows: Int = DotMatrix.rows) -> [Double] {
        let clamped = Double(max(0, min(1, level)))
        let ceiling = Double(max(0, min(1, peak)))
        let lit = clamped * Double(rows)
        return dots.map { dot in
            let depth = Double(rows - dot.row)
            if depth <= lit { return 1 }
            if depth - 1 < lit { return 0.35 + 0.65 * (lit - (depth - 1)) }
            let isPeakRow = Double(rows - dot.row) - 1 < ceiling * Double(rows)
            return isPeakRow ? 0.3 : 0.16
        }
    }

    static func wave(_ dots: [MatrixDot], frame: Int, frameCount: Int, rows: Int = DotMatrix.rows) -> [Double] {
        let count = max(1, frameCount)
        let phase = Double(frame % count) / Double(count)
        return dots.map { dot in
            let position = Double(dot.row) / Double(max(1, rows - 1))
            let distance = abs(position - phase)
            let folded = min(distance, 1 - distance)
            return 0.18 + 0.82 * max(0, 1 - folded * 3)
        }
    }

    static func chase(_ dots: [MatrixDot], frame: Int, frameCount: Int) -> [Double] {
        let count = max(1, frameCount)
        let head = Double(frame % count) / Double(count)
        return dots.map { dot in
            let angle = atan2(dot.y - 0.6, dot.x - 0.5) / (2 * Double.pi)
            let position = angle < 0 ? angle + 1 : angle
            var distance = position - head
            if distance < 0 { distance += 1 }
            return 0.22 + 0.78 * max(0, 1 - distance * 1.9)
        }
    }
}
