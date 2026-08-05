import CoreGraphics
import Foundation
import SwiftUI

enum SVGPath {
    static func cgPath(from d: String) -> CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var scanner = Tokenizer(d)
        var command: Character?

        while true {
            if let next = scanner.peekCommand() {
                command = next
                scanner.advanceCommand()
            } else if scanner.atEnd {
                break
            } else if command == nil {
                break
            } else if command == "M" {
                command = "L"
            } else if command == "m" {
                command = "l"
            }

            guard let cmd = command else { break }
            let relative = cmd.isLowercase
            let base = relative ? current : .zero

            switch Character(cmd.uppercased()) {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                start = current
                path.move(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: base.x + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: base.y + y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1 = reflect(lastControl, around: current)
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                lastControl = nil
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = reflect(lastQuadControl, around: current)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                lastControl = nil
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(), let largeArc = scanner.flag(),
                      let sweep = scanner.flag(), let x = scanner.number(), let y = scanner.number()
                else { return path }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                addArc(
                    to: path,
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    rotation: rotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                current = end
                lastControl = nil
                lastQuadControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
                lastQuadControl = nil
            default:
                return path
            }
        }

        return path
    }

    static func path(from d: String) -> Path {
        Path(cgPath(from: d))
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    private static func addArc(
        to path: CGMutablePath,
        from origin: CGPoint,
        to end: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        rotation: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if origin == end { return }
        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (origin.x - end.x) / 2
        let dy2 = (origin.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coef = -coef }

        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (origin.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (origin.y + end.y) / 2

        let theta1 = angle(ux: 1, uy: 0, vx: (x1p - cxp) / rx, vy: (y1p - cyp) / ry)
        var delta = angle(
            ux: (x1p - cxp) / rx,
            uy: (y1p - cyp) / ry,
            vx: (-x1p - cxp) / rx,
            vy: (-y1p - cyp) / ry
        )
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        var from = origin

        for _ in 0..<segments {
            let cosT1 = cos(theta)
            let sinT1 = sin(theta)
            let theta2 = theta + step
            let cosT2 = cos(theta2)
            let sinT2 = sin(theta2)

            let to = point(cx: cx, cy: cy, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, cosT: cosT2, sinT: sinT2)
            let d1 = derivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, cosT: cosT1, sinT: sinT1)
            let d2 = derivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, cosT: cosT2, sinT: sinT2)

            let c1 = CGPoint(x: from.x + alpha * d1.x, y: from.y + alpha * d1.y)
            let c2 = CGPoint(x: to.x - alpha * d2.x, y: to.y - alpha * d2.y)
            path.addCurve(to: to, control1: c1, control2: c2)

            theta = theta2
            from = to
        }
    }

    private static func point(
        cx: CGFloat,
        cy: CGFloat,
        rx: CGFloat,
        ry: CGFloat,
        cosPhi: CGFloat,
        sinPhi: CGFloat,
        cosT: CGFloat,
        sinT: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: cx + rx * cosT * cosPhi - ry * sinT * sinPhi,
            y: cy + rx * cosT * sinPhi + ry * sinT * cosPhi
        )
    }

    private static func derivative(
        rx: CGFloat,
        ry: CGFloat,
        cosPhi: CGFloat,
        sinPhi: CGFloat,
        cosT: CGFloat,
        sinT: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: -rx * sinT * cosPhi - ry * cosT * sinPhi,
            y: -rx * sinT * sinPhi + ry * cosT * cosPhi
        )
    }

    private static func angle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        guard len > 0 else { return 0 }
        var value = acos(min(1, max(-1, dot / len)))
        if ux * vy - uy * vx < 0 { value = -value }
        return value
    }
}

private struct Tokenizer {
    private let chars: [Character]
    private var index: Int = 0

    init(_ source: String) {
        chars = Array(source)
    }

    var atEnd: Bool {
        var i = index
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" {
            i += 1
        }
        return i >= chars.count
    }

    mutating func peekCommand() -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
    }

    mutating func advanceCommand() {
        index += 1
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        if c == "0" || c == "1" {
            index += 1
            return c == "1"
        }
        return number().map { $0 != 0 }
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let startIndex = index
        if chars[index] == "+" || chars[index] == "-" { index += 1 }
        var sawDigit = false
        while index < chars.count, chars[index].isNumber {
            index += 1
            sawDigit = true
        }
        if index < chars.count, chars[index] == "." {
            index += 1
            while index < chars.count, chars[index].isNumber {
                index += 1
                sawDigit = true
            }
        }
        guard sawDigit else {
            index = startIndex
            return nil
        }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            let mark = index
            index += 1
            if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            var sawExponent = false
            while index < chars.count, chars[index].isNumber {
                index += 1
                sawExponent = true
            }
            if !sawExponent { index = mark }
        }
        guard let value = Double(String(chars[startIndex..<index])) else { return nil }
        return CGFloat(value)
    }

    private mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                index += 1
            } else {
                break
            }
        }
    }
}
