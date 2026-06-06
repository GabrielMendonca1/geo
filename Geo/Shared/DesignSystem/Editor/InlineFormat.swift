import Foundation
import AppKit

enum InlineStyle: Hashable {
    case bold
    case italic
    case strikethrough
    case code
    case wikiLink
    case wikiLinkWithMeta(target: String, anchor: String?, isEmbed: Bool)
    case link(url: String)
    case autoLink(url: String)
    case math
    case highlight
    case embed
    case tag(name: String)
}

extension NSAttributedString.Key {
    static let geoWikiLink = NSAttributedString.Key("geo.wikiLink")
    static let geoWikiTarget = NSAttributedString.Key("geo.wikiTarget")
    static let geoWikiAnchor = NSAttributedString.Key("geo.wikiAnchor")
    static let geoEmbed = NSAttributedString.Key("geo.embed")
    static let geoTag = NSAttributedString.Key("geo.tag")
    static let geoLink = NSAttributedString.Key("geo.link")
    static let geoAutoLink = NSAttributedString.Key("geo.autoLink")
    static let geoMath = NSAttributedString.Key("geo.math")
    static let geoHighlight = NSAttributedString.Key("geo.highlight")
}

enum HighlightStyle {
    static var color: NSColor { NSColor.systemYellow.withAlphaComponent(0.35) }
}

struct InlineSpan: Equatable, Hashable {
    var range: NSRange
    var styles: Set<InlineStyle>

    static func normalized(_ spans: [InlineSpan]) -> [InlineSpan] {
        let nonEmpty = spans.filter { $0.range.length > 0 && !$0.styles.isEmpty }
        guard !nonEmpty.isEmpty else { return [] }

        var styleRanges: [InlineStyle: IndexSet] = [:]
        for span in nonEmpty {
            for style in span.styles {
                let r = span.range.location..<(span.range.location + span.range.length)
                styleRanges[style, default: IndexSet()].insert(integersIn: r)
            }
        }

        var result: [InlineSpan] = []
        for (style, indexSet) in styleRanges {
            for range in indexSet.rangeView {
                result.append(InlineSpan(
                    range: NSRange(location: range.lowerBound, length: range.count),
                    styles: [style]))
            }
        }

        result.sort { $0.range.location < $1.range.location }
        return result
    }
}

enum InlineParser {

    private static let wikiLinkRegex = try! NSRegularExpression(pattern: "(!?)\\[\\[([^\\[\\]\\n]*)\\]\\]")
    private static let linkRegex = try! NSRegularExpression(pattern: "(?<![\\[\\\\])\\[([^\\[\\]]+)\\]\\(((?:[^()]|\\([^()]*\\))+)\\)")
    private static let bareURLRegex = try! NSRegularExpression(pattern: "(?<![\\w@/])https?://[^\\s<>\\[\\]()]+[^\\s<>\\[\\]().,;:!?'\"]")
    private static let codeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let boldItalicRegex = try! NSRegularExpression(pattern: "\\*\\*\\*(.+?)\\*\\*\\*")
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")
    private static let underscoreItalicRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])_([^_\\s](?:[^_\\n]*?[^_\\s])?)_(?![A-Za-z0-9_])")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~(.+?)~~")
    private static let highlightRegex = try! NSRegularExpression(pattern: "==(.+?)==")
    private static let mathRegex = try! NSRegularExpression(pattern: "(?<![\\$0-9])\\$(\\S[^$\\n]*?\\S|\\S)\\$(?![\\$0-9])")
    private static let tagRegex = try! NSRegularExpression(pattern: "(^|[\\s(\\[\\{,.;:!?/\\\\\\-\\u2013\\u2014])(#[A-Za-z0-9_/\\-]+)")

    static func parse(_ markdown: String) -> (String, [InlineSpan]) {
        guard !markdown.isEmpty else { return ("", []) }

        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var contentRanges: [(InlineStyle, NSRange)] = []
        var markerSet = IndexSet()

        var codeFullRanges: [NSRange] = []
        for m in codeRegex.matches(in: markdown, range: fullRange) {
            let cr = m.range(at: 1)
            contentRanges.append((.code, cr))
            markerSet.insert(integersIn: m.range.location..<(m.range.location + 1))
            markerSet.insert(integersIn: NSMaxRange(cr)..<(NSMaxRange(cr) + 1))
            codeFullRanges.append(m.range)
        }

        // True only when `range` is FULLY enclosed by some code span. A bold
        // that wraps an inline-code span (e.g. `**neg `code` rito**`) crosses
        // the code boundary but isn't inside it — must not be skipped.
        func isInsideCode(_ range: NSRange) -> Bool {
            codeFullRanges.contains {
                $0.location <= range.location && NSMaxRange($0) >= NSMaxRange(range)
            }
        }

        var wikiLinkFullRanges: [NSRange] = []

        for m in wikiLinkRegex.matches(in: markdown, range: fullRange) {
            if isInsideCode(m.range) { continue }
            let bangRange = m.range(at: 1)
            let innerRange = m.range(at: 2)
            let isEmbed = bangRange.length > 0
            let inner = ns.substring(with: innerRange)
            var aliasStartInOriginal: Int?
            var anchor: String?
            var target: String
            if let pipeOffset = inner.firstIndex(of: "|") {
                let pageRaw = String(inner[inner.startIndex..<pipeOffset])
                let pageBytes = (pageRaw as NSString).length
                aliasStartInOriginal = innerRange.location + pageBytes
                target = pageRaw
            } else {
                target = inner
            }
            if let hashIdx = target.firstIndex(of: "#") {
                anchor = String(target[target.index(after: hashIdx)..<target.endIndex])
                target = String(target[target.startIndex..<hashIdx])
            } else if let caretIdx = target.firstIndex(of: "^") {
                anchor = String(target[caretIdx..<target.endIndex])
                target = String(target[target.startIndex..<caretIdx])
            }
            target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if target.isEmpty { continue }
            if let alias = aliasStartInOriginal {
                let aliasLength = NSMaxRange(innerRange) - alias - 1
                if aliasLength <= 0 {
                    contentRanges.append((.wikiLinkWithMeta(target: target, anchor: anchor, isEmbed: isEmbed), m.range))
                    wikiLinkFullRanges.append(m.range)
                    continue
                }
                let aliasContent = NSRange(location: alias + 1, length: aliasLength)
                contentRanges.append((.wikiLinkWithMeta(target: target, anchor: anchor, isEmbed: isEmbed), aliasContent))
                let bangCount = isEmbed ? 1 : 0
                markerSet.insert(integersIn: m.range.location..<(m.range.location + 2 + bangCount))
                markerSet.insert(integersIn: alias..<(alias + 1))
                markerSet.insert(integersIn: NSMaxRange(aliasContent)..<NSMaxRange(m.range))
            } else {
                contentRanges.append((.wikiLinkWithMeta(target: target, anchor: anchor, isEmbed: isEmbed), innerRange))
                let bangCount = isEmbed ? 1 : 0
                markerSet.insert(integersIn: m.range.location..<(m.range.location + 2 + bangCount))
                markerSet.insert(integersIn: NSMaxRange(innerRange)..<NSMaxRange(m.range))
            }
            wikiLinkFullRanges.append(m.range)
        }

        func isInsideWikiLink(_ range: NSRange) -> Bool {
            wikiLinkFullRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var mathFullRanges: [NSRange] = []

        for m in mathRegex.matches(in: markdown, range: fullRange) {
            if isInsideCode(m.range) || isInsideWikiLink(m.range) { continue }
            let cr = m.range(at: 1)
            contentRanges.append((.math, cr))
            markerSet.insert(integersIn: m.range.location..<(m.range.location + 1))
            markerSet.insert(integersIn: NSMaxRange(cr)..<(NSMaxRange(cr) + 1))
            mathFullRanges.append(m.range)
        }

        func isInsideMath(_ range: NSRange) -> Bool {
            mathFullRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var linkFullRanges: [NSRange] = []
        var linkTextRanges: [NSRange] = []

        for m in linkRegex.matches(in: markdown, range: fullRange) {
            if isInsideCode(m.range) || isInsideWikiLink(m.range) { continue }
            let textRange = m.range(at: 1)
            let url = ns.substring(with: m.range(at: 2))
            contentRanges.append((.link(url: url), textRange))
            markerSet.insert(integersIn: m.range.location..<(m.range.location + 1))
            markerSet.insert(integersIn: NSMaxRange(textRange)..<NSMaxRange(m.range))
            linkFullRanges.append(m.range)
            linkTextRanges.append(textRange)
        }

        func isInsideLinkText(_ range: NSRange) -> Bool {
            linkTextRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        func isInsideMarkdownLink(_ range: NSRange) -> Bool {
            linkFullRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var autoLinkRanges: [NSRange] = []
        for m in bareURLRegex.matches(in: markdown, range: fullRange) {
            if isInsideCode(m.range) || isInsideWikiLink(m.range) || isInsideMath(m.range) || isInsideMarkdownLink(m.range) { continue }
            let url = ns.substring(with: m.range)
            contentRanges.append((.autoLink(url: url), m.range))
            autoLinkRanges.append(m.range)
        }

        func isInsideAutoLink(_ range: NSRange) -> Bool {
            autoLinkRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        func nestedSymmetric(_ regex: NSRegularExpression, style: InlineStyle, markerWidth: Int) {
            for m in regex.matches(in: markdown, range: fullRange) {
                if isInsideCode(m.range) || isInsideWikiLink(m.range) || isInsideMath(m.range) || isInsideAutoLink(m.range) { continue }
                let cr = m.range(at: 1)
                contentRanges.append((style, cr))
                markerSet.insert(integersIn: m.range.location..<(m.range.location + markerWidth))
                markerSet.insert(integersIn: NSMaxRange(cr)..<(NSMaxRange(cr) + markerWidth))
            }
        }
        // `***text***` — bold + italic combo. Apply BEFORE bold/italic so the
        // outer `***` markers are claimed first (avoiding the non-greedy bold
        // regex matching `**` + `*text*` + `**` and leaving stray asterisks).
        for m in boldItalicRegex.matches(in: markdown, range: fullRange) {
            if isInsideCode(m.range) || isInsideWikiLink(m.range) || isInsideMath(m.range) { continue }
            let cr = m.range(at: 1)
            contentRanges.append((.bold, cr))
            contentRanges.append((.italic, cr))
            markerSet.insert(integersIn: m.range.location..<(m.range.location + 3))
            markerSet.insert(integersIn: NSMaxRange(cr)..<(NSMaxRange(cr) + 3))
        }
        nestedSymmetric(boldRegex, style: .bold, markerWidth: 2)
        nestedSymmetric(strikeRegex, style: .strikethrough, markerWidth: 2)
        nestedSymmetric(highlightRegex, style: .highlight, markerWidth: 2)
        nestedSymmetric(italicRegex, style: .italic, markerWidth: 1)
        nestedSymmetric(underscoreItalicRegex, style: .italic, markerWidth: 1)

        for m in tagRegex.matches(in: markdown, range: fullRange) {
            let tagRange = m.range(at: 2)
            if isInsideCode(tagRange) || isInsideWikiLink(tagRange) || isInsideMath(tagRange) || isInsideLinkText(tagRange) { continue }
            let name = ns.substring(with: NSRange(location: tagRange.location + 1, length: tagRange.length - 1))
            contentRanges.append((.tag(name: name), tagRange))
        }

        if contentRanges.isEmpty { return (markdown, []) }

        let mutable = NSMutableString()
        var pos = 0
        for range in markerSet.rangeView {
            if pos < range.lowerBound {
                mutable.append(ns.substring(with: NSRange(location: pos, length: range.lowerBound - pos)))
            }
            pos = range.upperBound
        }
        if pos < ns.length {
            mutable.append(ns.substring(from: pos))
        }
        let cleanString = mutable as String

        func adjustedPosition(_ originalPos: Int) -> Int {
            var removed = 0
            for range in markerSet.rangeView {
                if range.lowerBound >= originalPos { break }
                removed += min(range.upperBound, originalPos) - range.lowerBound
            }
            return originalPos - removed
        }

        var spans: [InlineSpan] = []
        for (style, cr) in contentRanges {
            let newStart = adjustedPosition(cr.location)
            let newEnd = adjustedPosition(NSMaxRange(cr))
            let length = newEnd - newStart
            if length > 0 {
                spans.append(InlineSpan(range: NSRange(location: newStart, length: length), styles: [style]))
            }
        }

        return (cleanString, spans)
    }
}

enum InlineSerializer {
    static func serialize(content: String, spans: [InlineSpan]) -> String {
        guard !content.isEmpty, !spans.isEmpty else { return content }

        let spans = InlineSpan.normalized(spans)
        guard !spans.isEmpty else { return content }

        let ns = content as NSString
        let length = ns.length

        var linkSpans: [(NSRange, String)] = []
        var wikiMetaSpans: [(NSRange, String, String?, Bool)] = []
        var nonLinkSpans: [InlineSpan] = []
        for span in spans {
            guard span.range.length > 0 else { continue }
            for style in span.styles {
                if case .link(let url) = style {
                    linkSpans.append((span.range, url))
                } else if case .wikiLinkWithMeta(let target, let anchor, let isEmbed) = style {
                    wikiMetaSpans.append((span.range, target, anchor, isEmbed))
                } else if case .tag = style {
                    continue
                } else if case .autoLink = style {
                    continue
                } else {
                    nonLinkSpans.append(InlineSpan(range: span.range, styles: [style]))
                }
            }
        }

        var opens: [Int: Set<InlineStyle>] = [:]
        var closes: [Int: Set<InlineStyle>] = [:]

        for span in nonLinkSpans {
            guard span.range.length > 0 else { continue }
            for style in span.styles {
                opens[span.range.location, default: []].insert(style)
                closes[NSMaxRange(span.range), default: []].insert(style)
            }
        }

        var linkOpens: [Int: String] = [:]
        var linkCloses: [Int: String] = [:]
        for (range, url) in linkSpans {
            linkOpens[range.location] = url
            linkCloses[NSMaxRange(range)] = url
        }

        var wikiOpens: [Int: (target: String, anchor: String?, isEmbed: Bool, contentLength: Int)] = [:]
        var wikiCloses: [Int: Bool] = [:]
        var wikiWrapped: Set<Int> = []
        for (range, target, anchor, isEmbed) in wikiMetaSpans {
            wikiOpens[range.location] = (target, anchor, isEmbed, range.length)
            wikiCloses[NSMaxRange(range)] = true
            let content = range.location + range.length <= length ? ns.substring(with: range) : ""
            if content.hasPrefix("[[") && content.hasSuffix("]]") {
                wikiWrapped.insert(NSMaxRange(range))
            }
        }

        var positions = Set<Int>()
        positions.formUnion(opens.keys)
        positions.formUnion(closes.keys)
        positions.formUnion(linkOpens.keys)
        positions.formUnion(linkCloses.keys)
        positions.formUnion(wikiOpens.keys)
        positions.formUnion(wikiCloses.keys)
        let sorted = positions.sorted()

        var result = ""
        var pos = 0

        let closeOrder: [InlineStyle] = [.wikiLink, .code, .highlight, .strikethrough, .italic, .bold]
        let openOrder: [InlineStyle] = [.bold, .italic, .strikethrough, .highlight, .code, .wikiLink]

        for p in sorted {
            if p > pos && p <= length {
                result += ns.substring(with: NSRange(location: pos, length: p - pos))
            }
            pos = p

            if let closing = closes[p] {
                for style in closeOrder where closing.contains(style) { result += marker(for: style, opening: false) }
            }
            if let url = linkCloses[p] { result += "](\(url))" }
            if wikiCloses[p] == true && !wikiWrapped.contains(p) {
                result += "]]"
            }
            if let meta = wikiOpens[p] {
                let prefix = meta.isEmbed ? "![[" : "[["
                var pageWithAnchor = meta.target
                if let anchor = meta.anchor {
                    if anchor.hasPrefix("^") {
                        pageWithAnchor += anchor
                    } else {
                        pageWithAnchor += "#" + anchor
                    }
                }
                let upcomingContent = p + meta.contentLength <= length ? ns.substring(with: NSRange(location: p, length: meta.contentLength)) : ""
                if upcomingContent.hasPrefix("[[") && upcomingContent.hasSuffix("]]") {
                } else if upcomingContent == pageWithAnchor || upcomingContent.trimmingCharacters(in: .whitespaces) == pageWithAnchor {
                    result += prefix
                } else {
                    result += prefix + pageWithAnchor + "|"
                }
            }
            if linkOpens[p] != nil { result += "[" }
            if let opening = opens[p] {
                for style in openOrder where opening.contains(style) { result += marker(for: style, opening: true) }
            }
        }

        if pos < length {
            result += ns.substring(from: pos)
        }

        return result
    }

    private static func marker(for style: InlineStyle, opening: Bool) -> String {
        switch style {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        case .wikiLink: return opening ? "[[" : "]]"
        case .wikiLinkWithMeta: return ""
        case .math: return "$"
        case .link: return ""
        case .autoLink: return ""
        case .highlight: return "=="
        case .embed: return ""
        case .tag: return ""
        }
    }
}

final class EditorFontCache {
    static let shared = EditorFontCache()

    private struct Key: Hashable {
        let pointSize: CGFloat
        let style: Style
    }

    enum Style: Hashable {
        case bold, italic, boldItalic, code
    }

    private var cache: [Key: NSFont] = [:]

    func font(for base: NSFont, style: Style) -> NSFont {
        let key = Key(pointSize: base.pointSize, style: style)
        if let cached = cache[key] { return cached }
        let result: NSFont
        switch style {
        case .bold:
            let bold = FontManager.geistMono(size: base.pointSize, weight: .bold)
            result = bold.fontName != base.fontName ? bold : NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .bold)
        case .italic:
            var matrix = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(12.0 * .pi / 180.0)), d: 1, tx: 0, ty: 0)
            result = CTFontCreateCopyWithAttributes(base as CTFont, base.pointSize, &matrix, nil) as NSFont
        case .boldItalic:
            let bold = font(for: base, style: .bold)
            result = font(for: bold, style: .italic)
        case .code:
            result = NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: .regular)
        }
        cache[key] = result
        return result
    }

    func invalidate() {
        cache.removeAll()
    }
}

enum SpanStyler {
    static func boldFont(for base: NSFont) -> NSFont {
        EditorFontCache.shared.font(for: base, style: .bold)
    }

    static func italicFont(for base: NSFont) -> NSFont {
        EditorFontCache.shared.font(for: base, style: .italic)
    }

    static func boldItalicFont(for base: NSFont) -> NSFont {
        EditorFontCache.shared.font(for: base, style: .boldItalic)
    }

    static func codeFont(for base: NSFont) -> NSFont {
        EditorFontCache.shared.font(for: base, style: .code)
    }

    static func apply(spans: [InlineSpan], to ts: NSTextStorage, baseFont: NSFont) {
        for span in spans {
            guard span.range.length > 0 else { continue }
            let r = NSIntersectionRange(span.range, NSRange(location: 0, length: ts.length))
            guard r.length > 0 else { continue }

            if span.styles.contains(.code) {
                ts.addAttribute(.font, value: codeFont(for: baseFont), range: r)
                ts.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: r)
            } else {
                let hasBold = span.styles.contains(.bold)
                let hasItalic = span.styles.contains(.italic)
                if hasBold && hasItalic {
                    ts.addAttribute(.font, value: boldItalicFont(for: baseFont), range: r)
                } else if hasBold {
                    ts.addAttribute(.font, value: boldFont(for: baseFont), range: r)
                } else if hasItalic {
                    ts.addAttribute(.font, value: italicFont(for: baseFont), range: r)
                }
            }

            if span.styles.contains(.strikethrough) {
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }

            if span.styles.contains(.highlight) && !span.styles.contains(.code) {
                ts.addAttribute(.backgroundColor, value: HighlightStyle.color, range: r)
                ts.addAttribute(.geoHighlight, value: true, range: r)
            }

            if span.styles.contains(.wikiLink) {
                ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                ts.addAttribute(.geoWikiLink, value: true, range: r)
            }

            for style in span.styles {
                if case .wikiLinkWithMeta(let target, let anchor, let isEmbed) = style {
                    ts.addAttribute(.geoWikiLink, value: true, range: r)
                    ts.addAttribute(.geoWikiTarget, value: target, range: r)
                    if let anchor { ts.addAttribute(.geoWikiAnchor, value: anchor, range: r) }
                    if isEmbed {
                        ts.addAttribute(.geoEmbed, value: true, range: r)
                        ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                        ts.addAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.12), range: r)
                        ts.addAttribute(.font, value: boldFont(for: baseFont), range: r)
                    } else {
                        ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                        ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                    }
                }
                if case .tag(let name) = style {
                    ts.addAttribute(.geoTag, value: name, range: r)
                    ts.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: r)
                }
            }

            if span.styles.contains(.math) {
                let latex = (ts.string as NSString).substring(with: r)
                let foreground = ts.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor ?? .labelColor
                let rendered = MathRenderer.render(latex: latex, fontSize: baseFont.pointSize, color: foreground)
                ts.replaceCharacters(in: r, with: rendered)
                let newRange = NSRange(location: r.location, length: rendered.length)
                ts.addAttribute(.geoMath, value: latex, range: newRange)
            }

            for style in span.styles {
                if case .link(let url) = style {
                    ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                    ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                    ts.addAttribute(.geoLink, value: url, range: r)
                }
                if case .autoLink(let url) = style {
                    ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                    ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                    ts.addAttribute(.geoLink, value: url, range: r)
                    ts.addAttribute(.geoAutoLink, value: true, range: r)
                }
            }
        }
    }
}

enum SpanExtractor {
    static func extract(from ts: NSTextStorage, baseFont: NSFont) -> [InlineSpan] {
        guard ts.length > 0 else { return [] }

        let boldFontName = SpanStyler.boldFont(for: baseFont).fontName
        let codeFontObj = SpanStyler.codeFont(for: baseFont)
        var spans: [InlineSpan] = []

        ts.enumerateAttributes(in: NSRange(location: 0, length: ts.length)) { attrs, range, _ in
            var styles = Set<InlineStyle>()

            if let font = attrs[.font] as? NSFont {
                if font.fontName == codeFontObj.fontName && font.pointSize == codeFontObj.pointSize {
                    styles.insert(.code)
                } else {
                    if font.fontName == boldFontName { styles.insert(.bold) }
                    let matrix = CTFontGetMatrix(font as CTFont)
                    if matrix.c != 0 { styles.insert(.italic) }
                }
            }

            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                styles.insert(.strikethrough)
            }

            if let isWiki = attrs[.geoWikiLink] as? Bool, isWiki {
                if let target = attrs[.geoWikiTarget] as? String {
                    let anchor = attrs[.geoWikiAnchor] as? String
                    let isEmbed = (attrs[.geoEmbed] as? Bool) == true
                    styles.insert(.wikiLinkWithMeta(target: target, anchor: anchor, isEmbed: isEmbed))
                } else {
                    styles.insert(.wikiLink)
                }
            }

            if let tagName = attrs[.geoTag] as? String {
                styles.insert(.tag(name: tagName))
            }

            if let url = attrs[.geoLink] as? String {
                if (attrs[.geoAutoLink] as? Bool) == true {
                    styles.insert(.autoLink(url: url))
                } else {
                    styles.insert(.link(url: url))
                }
            }

            if attrs[.geoMath] is String {
                styles.insert(.math)
            }

            if let isHighlight = attrs[.geoHighlight] as? Bool, isHighlight {
                styles.insert(.highlight)
            }

            if !styles.isEmpty {
                spans.append(InlineSpan(range: range, styles: styles))
            }
        }

        return mergeAdjacent(spans)
    }

    private static func mergeAdjacent(_ spans: [InlineSpan]) -> [InlineSpan] {
        guard !spans.isEmpty else { return [] }
        var result = [spans[0]]
        for i in 1..<spans.count {
            let prev = result[result.count - 1]
            let curr = spans[i]
            if NSMaxRange(prev.range) == curr.range.location && prev.styles == curr.styles {
                result[result.count - 1].range.length += curr.range.length
            } else {
                result.append(curr)
            }
        }
        return result
    }
}

extension InlineSpan {
    static func split(spans: [InlineSpan], at position: Int) -> (before: [InlineSpan], after: [InlineSpan]) {
        var before: [InlineSpan] = []
        var after: [InlineSpan] = []
        for span in spans {
            let end = NSMaxRange(span.range)
            if end <= position {
                before.append(span)
            } else if span.range.location >= position {
                after.append(InlineSpan(
                    range: NSRange(location: span.range.location - position, length: span.range.length),
                    styles: span.styles))
            } else {
                before.append(InlineSpan(
                    range: NSRange(location: span.range.location, length: position - span.range.location),
                    styles: span.styles))
                after.append(InlineSpan(
                    range: NSRange(location: 0, length: end - position),
                    styles: span.styles))
            }
        }
        return (before, after)
    }

    static func shifted(_ spans: [InlineSpan], by offset: Int) -> [InlineSpan] {
        spans.map { InlineSpan(range: NSRange(location: $0.range.location + offset, length: $0.range.length), styles: $0.styles) }
    }
}
