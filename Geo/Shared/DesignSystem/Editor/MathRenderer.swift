import Foundation
import AppKit

enum MathRenderer {

    static let greekLetters: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω",
        "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε",
        "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
        "Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Pi": "Π",
        "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ", "Phi": "Φ",
        "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω",
        "varepsilon": "ε", "varphi": "φ", "varpi": "ϖ", "varrho": "ϱ",
        "varsigma": "ς", "vartheta": "ϑ",
    ]

    static let operators: [String: String] = [
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮",
        "lim": "lim", "inf": "inf", "sup": "sup",
        "max": "max", "min": "min", "log": "log", "ln": "ln",
        "sin": "sin", "cos": "cos", "tan": "tan", "exp": "exp",
        "infty": "∞", "partial": "∂", "nabla": "∇",
        "forall": "∀", "exists": "∃", "nexists": "∄",
        "emptyset": "∅", "wp": "℘", "ell": "ℓ",
        "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ",
    ]

    static let relations: [String: String] = [
        "leq": "≤", "geq": "≥", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "in": "∈", "notin": "∉", "ni": "∋",
        "ll": "≪", "gg": "≫",
        "prec": "≺", "succ": "≻",
        "perp": "⊥", "parallel": "∥",
    ]

    static let arrows: [String: String] = [
        "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔",
        "uparrow": "↑", "downarrow": "↓",
        "mapsto": "↦", "hookrightarrow": "↪", "hookleftarrow": "↩",
        "to": "→", "gets": "←",
        "implies": "⟹", "iff": "⟺",
    ]

    static let miscSymbols: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·",
        "star": "⋆", "ast": "∗", "circ": "∘", "bullet": "•",
        "oplus": "⊕", "otimes": "⊗", "odot": "⊙",
        "dagger": "†", "ddagger": "‡",
        "vee": "∨", "wedge": "∧", "cap": "∩", "cup": "∪",
        "neg": "¬", "lnot": "¬",
        "angle": "∠", "triangle": "△",
        "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "quad": "  ", "qquad": "    ",
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ",
    ]

    static let subscriptChars: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ",
        "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "r": "ᵣ", "u": "ᵤ", "v": "ᵥ",
    ]

    static let doubleStruck: [Character: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ",
        "P": "ℙ", "H": "ℍ",
    ]

    static let scriptLetters: [Character: String] = [
        "L": "ℒ", "H": "ℋ", "F": "ℱ", "P": "𝒫",
        "B": "ℬ", "E": "ℰ", "M": "ℳ", "N": "𝒩",
        "R": "ℛ", "S": "𝒮",
    ]

    static func render(latex: String, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSAttributedString(string: "")
        }

        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: color,
        ]

        var chars = Array(trimmed)
        var pos = 0

        while pos < chars.count {
            let ch = chars[pos]

            if ch == "\\" && pos + 1 < chars.count && chars[pos + 1] == "\\" {
                result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
                pos += 2
                continue
            }

            if ch == "\\" {
                let cmdResult = parseCommand(chars: chars, from: pos + 1)
                let cmd = cmdResult.command
                pos = cmdResult.nextPos

                if cmd == "frac" {
                    let num = parseBraceGroup(chars: chars, from: &pos)
                    let den = parseBraceGroup(chars: chars, from: &pos)
                    let numRendered = render(latex: num, fontSize: fontSize * 0.8, color: color)
                    let denRendered = render(latex: den, fontSize: fontSize * 0.8, color: color)
                    result.append(numRendered)
                    result.append(NSAttributedString(string: "⁄", attributes: baseAttrs))
                    result.append(denRendered)
                    continue
                }

                if cmd == "sqrt" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    let innerRendered = render(latex: inner, fontSize: fontSize, color: color)
                    result.append(NSAttributedString(string: "√", attributes: baseAttrs))
                    result.append(innerRendered)
                    continue
                }

                if cmd == "mathbb" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    var mapped = ""
                    for c in inner {
                        if let ds = doubleStruck[c] { mapped += ds }
                        else { mapped += String(c) }
                    }
                    result.append(NSAttributedString(string: mapped, attributes: baseAttrs))
                    continue
                }

                if cmd == "mathcal" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    var mapped = ""
                    for c in inner {
                        if let sc = scriptLetters[c] { mapped += sc }
                        else { mapped += String(c) }
                    }
                    result.append(NSAttributedString(string: mapped, attributes: baseAttrs))
                    continue
                }

                if cmd == "text" || cmd == "mathrm" || cmd == "textrm" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    result.append(NSAttributedString(string: inner, attributes: baseAttrs))
                    continue
                }

                if cmd == "mathbf" || cmd == "textbf" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    let boldFont = NSFont.boldSystemFont(ofSize: fontSize)
                    var boldAttrs = baseAttrs
                    boldAttrs[.font] = boldFont
                    result.append(NSAttributedString(string: inner, attributes: boldAttrs))
                    continue
                }

                if cmd == "left" || cmd == "right" || cmd == "big" || cmd == "Big" || cmd == "bigg" || cmd == "Bigg" {
                    if pos < chars.count {
                        let delimChar = chars[pos]
                        if delimChar == "." {
                            pos += 1
                        } else {
                            result.append(NSAttributedString(string: String(delimChar), attributes: baseAttrs))
                            pos += 1
                        }
                    }
                    continue
                }

                if cmd == "overline" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    let innerRendered = render(latex: inner, fontSize: fontSize, color: color)
                    let mutable = NSMutableAttributedString(attributedString: innerRendered)
                    mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                        range: NSRange(location: 0, length: mutable.length))
                    result.append(mutable)
                    continue
                }

                if cmd == "underline" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    let innerRendered = render(latex: inner, fontSize: fontSize, color: color)
                    let mutable = NSMutableAttributedString(attributedString: innerRendered)
                    mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                        range: NSRange(location: 0, length: mutable.length))
                    result.append(mutable)
                    continue
                }

                if cmd == "hat" || cmd == "tilde" || cmd == "bar" || cmd == "vec" || cmd == "dot" {
                    let inner = parseBraceGroup(chars: chars, from: &pos)
                    let accent: String
                    switch cmd {
                    case "hat": accent = "\u{0302}"
                    case "tilde": accent = "\u{0303}"
                    case "bar": accent = "\u{0304}"
                    case "vec": accent = "\u{20D7}"
                    case "dot": accent = "\u{0307}"
                    default: accent = ""
                    }
                    result.append(NSAttributedString(string: inner + accent, attributes: baseAttrs))
                    continue
                }

                if let sym = greekLetters[cmd] {
                    result.append(NSAttributedString(string: sym, attributes: baseAttrs))
                    continue
                }
                if let sym = operators[cmd] {
                    result.append(NSAttributedString(string: sym, attributes: baseAttrs))
                    continue
                }
                if let sym = relations[cmd] {
                    result.append(NSAttributedString(string: sym, attributes: baseAttrs))
                    continue
                }
                if let sym = arrows[cmd] {
                    result.append(NSAttributedString(string: sym, attributes: baseAttrs))
                    continue
                }
                if let sym = miscSymbols[cmd] {
                    result.append(NSAttributedString(string: sym, attributes: baseAttrs))
                    continue
                }

                let fallbackFont = NSFont(name: "Menlo-Italic", size: fontSize * 0.9)
                    ?? NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
                let fallbackAttrs: [NSAttributedString.Key: Any] = [
                    .font: fallbackFont,
                    .foregroundColor: color.withAlphaComponent(0.7),
                ]
                result.append(NSAttributedString(string: "\\\(cmd)", attributes: fallbackAttrs))
                continue
            }

            if ch == "^" {
                pos += 1
                let group = parseSuperSubGroup(chars: chars, from: &pos)
                let unicodeVersion = toUnicodeSuperscript(group)
                if let uni = unicodeVersion {
                    result.append(NSAttributedString(string: uni, attributes: baseAttrs))
                } else {
                    let rendered = render(latex: group, fontSize: fontSize * 0.7, color: color)
                    let mutable = NSMutableAttributedString(attributedString: rendered)
                    mutable.addAttribute(.baselineOffset, value: fontSize * 0.35,
                                        range: NSRange(location: 0, length: mutable.length))
                    result.append(mutable)
                }
                continue
            }

            if ch == "_" {
                pos += 1
                let group = parseSuperSubGroup(chars: chars, from: &pos)
                let unicodeVersion = toUnicodeSubscript(group)
                if let uni = unicodeVersion {
                    result.append(NSAttributedString(string: uni, attributes: baseAttrs))
                } else {
                    let rendered = render(latex: group, fontSize: fontSize * 0.7, color: color)
                    let mutable = NSMutableAttributedString(attributedString: rendered)
                    mutable.addAttribute(.baselineOffset, value: -fontSize * 0.15,
                                        range: NSRange(location: 0, length: mutable.length))
                    result.append(mutable)
                }
                continue
            }

            if ch == "{" {
                pos += 1
                continue
            }
            if ch == "}" {
                pos += 1
                continue
            }

            if ch == "~" {
                result.append(NSAttributedString(string: " ", attributes: baseAttrs))
                pos += 1
                continue
            }

            if ch == "&" {
                result.append(NSAttributedString(string: "\t", attributes: baseAttrs))
                pos += 1
                continue
            }

            result.append(NSAttributedString(string: String(ch), attributes: baseAttrs))
            pos += 1
        }

        return result
    }

    private static func parseCommand(chars: [Character], from start: Int) -> (command: String, nextPos: Int) {
        var pos = start
        guard pos < chars.count else { return ("", pos) }

        if !chars[pos].isLetter {
            return (String(chars[pos]), pos + 1)
        }

        var cmd = ""
        while pos < chars.count && chars[pos].isLetter {
            cmd.append(chars[pos])
            pos += 1
        }

        if pos < chars.count && chars[pos] == " " {
            pos += 1
        }

        return (cmd, pos)
    }

    private static func parseBraceGroup(chars: [Character], from pos: inout Int) -> String {
        while pos < chars.count && chars[pos] == " " { pos += 1 }
        guard pos < chars.count && chars[pos] == "{" else {
            if pos < chars.count {
                let ch = chars[pos]
                pos += 1
                return String(ch)
            }
            return ""
        }
        pos += 1
        var depth = 1
        var content = ""
        while pos < chars.count && depth > 0 {
            if chars[pos] == "{" { depth += 1 }
            else if chars[pos] == "}" { depth -= 1; if depth == 0 { pos += 1; return content } }
            content.append(chars[pos])
            pos += 1
        }
        return content
    }

    private static func parseSuperSubGroup(chars: [Character], from pos: inout Int) -> String {
        guard pos < chars.count else { return "" }
        if chars[pos] == "{" {
            return parseBraceGroup(chars: chars, from: &pos)
        }
        if chars[pos] == "\\" {
            let cmdResult = parseCommand(chars: chars, from: pos + 1)
            pos = cmdResult.nextPos
            return "\\\(cmdResult.command)"
        }
        let ch = chars[pos]
        pos += 1
        return String(ch)
    }

    private static func toUnicodeSuperscript(_ text: String) -> String? {
        var result = ""
        for ch in text {
            guard let mapped = superscripts[ch] else { return nil }
            result.append(mapped)
        }
        return result.isEmpty ? nil : result
    }

    private static func toUnicodeSubscript(_ text: String) -> String? {
        var result = ""
        for ch in text {
            guard let mapped = subscriptChars[ch] else { return nil }
            result.append(mapped)
        }
        return result.isEmpty ? nil : result
    }
}
