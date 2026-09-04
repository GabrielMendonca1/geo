import Foundation

struct MatrixDot: Equatable {
    let row: Int
    let column: Int
    let x: Double
    let y: Double
}

enum DotMatrix {
    static let rows = 4

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

    static func rowCount(_ dots: [MatrixDot]) -> Int {
        (dots.map(\.row).max() ?? 0) + 1
    }

    static func level(
        _ dots: [MatrixDot],
        level: Float,
        peak: Float,
        frame: Int = 0,
        frameCount: Int = 1
    ) -> [Double] {
        let rows = rowCount(dots)
        let loudness = Double(max(0, min(1, level)))
        let ceiling = Double(max(0, min(1, peak)))
        let count = max(1, frameCount)
        let phase = Double(frame % count) / Double(count) * 2 * Double.pi
        return dots.map { dot in
            let swell = sin(phase + dot.x * 2.6 * Double.pi)
            let column = loudness * (1 + 0.42 * swell * loudness)
            let height = max(0, column) * Double(rows)
            let depth = Double(rows - dot.row)
            if depth <= height { return 1 }
            if depth - 1 < height { return 0.26 + 0.74 * (height - (depth - 1)) }
            if depth - 1 < ceiling * Double(rows) { return 0.38 }
            return 0.13
        }
    }

    static func wave(_ dots: [MatrixDot], frame: Int, frameCount: Int) -> [Double] {
        let rows = rowCount(dots)
        let count = max(1, frameCount)
        let phase = Double(frame % count) / Double(count)
        return dots.map { dot in
            let position = Double(dot.row) / Double(max(1, rows - 1))
            let distance = abs(position - phase)
            let folded = min(distance, 1 - distance)
            return 0.18 + 0.82 * max(0, 1 - folded * 3)
        }
    }

    static func columnCount(_ dots: [MatrixDot]) -> Int {
        (dots.map(\.column).max() ?? 0) + 1
    }

    static func rain(_ dots: [MatrixDot], frame: Int, frameCount: Int) -> [Double] {
        let rows = rowCount(dots)
        let count = max(1, frameCount)
        let span = Double(rows) + 1.6
        let head = Double(frame % count) / Double(count) * span
        let tail = 1.7
        return dots.map { dot in
            let lag = abs(dot.x - 0.5) * 0.7
            let distance = head - (Double(dot.row) + lag)
            guard distance >= 0, distance <= tail else { return 0.15 }
            let glow = 1 - distance / tail
            return 0.15 + 0.85 * glow * glow
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
