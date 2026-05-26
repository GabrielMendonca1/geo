import AppKit

struct SyntaxHighlighter {
    enum TokenType {
        case keyword
        case type
        case string
        case number
        case comment
        case attribute
        case tag
        case property
        case builtin
        case variable
        case punctuation
        case operator_
    }

    struct Token {
        let range: NSRange
        let type: TokenType
    }

    static func highlight(code: String, language: String?) -> [Token] {
        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        guard fullRange.length > 0 else { return [] }

        let lang = (language ?? "").lowercased()
        var tokens: [Token] = []
        var occupied = IndexSet()

        switch lang {
        case "html", "xml":
            tokenizeHTML(code, fullRange, &tokens, &occupied)
        case "css", "scss", "less":
            tokenizeCSS(code, fullRange, &tokens, &occupied)
        case "json", "jsonc":
            tokenizeJSON(code, fullRange, &tokens, &occupied)
        case "markdown", "md":
            tokenizeMarkdown(code, fullRange, &tokens, &occupied)
        case "sql":
            tokenizeSQL(code, fullRange, &tokens, &occupied)
        default:
            tokenizeGeneric(code, fullRange, lang, &tokens, &occupied)
        }

        return tokens
    }

    static func colorForToken(_ type: TokenType, isDark: Bool) -> NSColor {
        if isDark {
            switch type {
            case .keyword:     return NSColor(red: 0.776, green: 0.471, blue: 0.867, alpha: 1)
            case .type:        return NSColor(red: 0.898, green: 0.753, blue: 0.482, alpha: 1)
            case .string:      return NSColor(red: 0.596, green: 0.765, blue: 0.475, alpha: 1)
            case .number:      return NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1)
            case .comment:     return NSColor(red: 0.361, green: 0.388, blue: 0.439, alpha: 1)
            case .attribute:   return NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1)
            case .tag:         return NSColor(red: 0.878, green: 0.424, blue: 0.459, alpha: 1)
            case .property:    return NSColor(red: 0.380, green: 0.686, blue: 0.937, alpha: 1)
            case .builtin:     return NSColor(red: 0.337, green: 0.714, blue: 0.761, alpha: 1)
            case .variable:    return NSColor(red: 0.878, green: 0.424, blue: 0.459, alpha: 1)
            case .punctuation: return NSColor(red: 0.671, green: 0.698, blue: 0.749, alpha: 1)
            case .operator_:   return NSColor(red: 0.337, green: 0.714, blue: 0.761, alpha: 1)
            }
        } else {
            switch type {
            case .keyword:     return NSColor(red: 0.651, green: 0.149, blue: 0.643, alpha: 1)
            case .type:        return NSColor(red: 0.757, green: 0.514, blue: 0.004, alpha: 1)
            case .string:      return NSColor(red: 0.314, green: 0.631, blue: 0.310, alpha: 1)
            case .number:      return NSColor(red: 0.596, green: 0.408, blue: 0.004, alpha: 1)
            case .comment:     return NSColor(red: 0.627, green: 0.631, blue: 0.655, alpha: 1)
            case .attribute:   return NSColor(red: 0.596, green: 0.408, blue: 0.004, alpha: 1)
            case .tag:         return NSColor(red: 0.894, green: 0.337, blue: 0.286, alpha: 1)
            case .property:    return NSColor(red: 0.251, green: 0.471, blue: 0.949, alpha: 1)
            case .builtin:     return NSColor(red: 0.004, green: 0.518, blue: 0.737, alpha: 1)
            case .variable:    return NSColor(red: 0.894, green: 0.337, blue: 0.286, alpha: 1)
            case .punctuation: return NSColor(red: 0.220, green: 0.227, blue: 0.259, alpha: 1)
            case .operator_:   return NSColor(red: 0.004, green: 0.518, blue: 0.737, alpha: 1)
            }
        }
    }

    static var codeBlockBackground: (dark: NSColor, light: NSColor) {
        (NSColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1),
         NSColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1))
    }

    private static func addMatches(
        _ regex: NSRegularExpression,
        _ range: NSRange,
        _ code: String,
        _ type: TokenType,
        _ tokens: inout [Token],
        _ occupied: inout IndexSet,
        captureGroup: Int = 0
    ) {
        regex.enumerateMatches(in: code, range: range) { match, _, _ in
            guard let m = match else { return }
            let matchRange = captureGroup > 0 && captureGroup < m.numberOfRanges
                ? m.range(at: captureGroup) : m.range
            guard matchRange.length > 0, matchRange.location != NSNotFound else { return }
            let intRange = matchRange.location..<(matchRange.location + matchRange.length)
            guard occupied.intersection(IndexSet(integersIn: intRange)).isEmpty else { return }
            tokens.append(Token(range: matchRange, type: type))
            occupied.insert(integersIn: intRange)
        }
    }

    private static let slashCommentRegex = try! NSRegularExpression(pattern: "//[^\n]*")
    private static let hashCommentRegex = try! NSRegularExpression(pattern: "#[^\n]*")
    private static let multiLineCommentRegex = try! NSRegularExpression(pattern: "/\\*.*?\\*/", options: .dotMatchesLineSeparators)
    private static let doubleStringRegex = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    private static let singleStringRegex = try! NSRegularExpression(pattern: "'(?:[^'\\\\]|\\\\.)*'")
    private static let backtickStringRegex = try! NSRegularExpression(pattern: "`(?:[^`\\\\]|\\\\.)*`")
    private static let tripleDoubleStringRegex = try! NSRegularExpression(pattern: "\"\"\"[\\s\\S]*?\"\"\"")
    private static let tripleSingleStringRegex = try! NSRegularExpression(pattern: "'''[\\s\\S]*?'''")
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b(?:0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\\d[\\d_]*\\.?[\\d_]*(?:[eE][+-]?\\d+)?)\\b")
    private static let typeRegex = try! NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b")
    private static let swiftAttributeRegex = try! NSRegularExpression(pattern: "@[a-zA-Z_][a-zA-Z0-9_]*")
    private static let pythonDecoratorRegex = try! NSRegularExpression(pattern: "@[a-zA-Z_][a-zA-Z0-9_.]*")
    private static let shellVariableRegex = try! NSRegularExpression(pattern: "\\$\\{?[a-zA-Z_][a-zA-Z0-9_]*\\}?|\\$[0-9#@!?*$-]")
    private static let htmlTagRegex = try! NSRegularExpression(pattern: "</?([a-zA-Z][a-zA-Z0-9-]*)(?:\\s|>|/>|$)")
    private static let htmlAttrRegex = try! NSRegularExpression(pattern: "\\s([a-zA-Z][a-zA-Z0-9-]*)\\s*=")
    private static let htmlCommentRegex = try! NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators)
    private static let cssPropertyRegex = try! NSRegularExpression(pattern: "(?<=^\\s*|;\\s*|\\{\\s*)([a-z-]+)\\s*:", options: .anchorsMatchLines)
    private static let cssSelectorRegex = try! NSRegularExpression(pattern: "^\\s*([.#]?[a-zA-Z][a-zA-Z0-9_-]*(?:\\s*[,>+~]\\s*[.#]?[a-zA-Z][a-zA-Z0-9_-]*)*)\\s*\\{", options: .anchorsMatchLines)
    private static let cssColorRegex = try! NSRegularExpression(pattern: "#[0-9a-fA-F]{3,8}\\b")
    private static let cssCommentRegex = try! NSRegularExpression(pattern: "/\\*.*?\\*/", options: .dotMatchesLineSeparators)
    private static let jsonKeyRegex = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"\\s*:")
    private static let jsonStringRegex = try! NSRegularExpression(pattern: ":\\s*(\"(?:[^\"\\\\]|\\\\.)*\")")
    private static let jsonBoolNullRegex = try! NSRegularExpression(pattern: "\\b(true|false|null)\\b")
    private static let mdHeaderRegex = try! NSRegularExpression(pattern: "^#{1,6}\\s+.*$", options: .anchorsMatchLines)
    private static let mdBoldRegex = try! NSRegularExpression(pattern: "\\*\\*.+?\\*\\*")
    private static let mdItalicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*).+?(?<!\\*)\\*(?!\\*)")
    private static let mdCodeRegex = try! NSRegularExpression(pattern: "`[^`]+`")
    private static let mdLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)")
    private static let sqlKeywordRegex = try! NSRegularExpression(
        pattern: "\\b(?:SELECT|FROM|WHERE|INSERT|INTO|UPDATE|SET|DELETE|CREATE|DROP|ALTER|TABLE|INDEX|VIEW|JOIN|INNER|LEFT|RIGHT|OUTER|FULL|CROSS|ON|AND|OR|NOT|IN|IS|NULL|LIKE|BETWEEN|EXISTS|HAVING|GROUP|BY|ORDER|ASC|DESC|LIMIT|OFFSET|UNION|ALL|AS|DISTINCT|COUNT|SUM|AVG|MIN|MAX|CASE|WHEN|THEN|ELSE|END|VALUES|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|CHECK|UNIQUE|CASCADE|TRUNCATE|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE|WITH)\\b",
        options: .caseInsensitive
    )
    private static let sqlCommentRegex = try! NSRegularExpression(pattern: "--[^\n]*")

    private static let hashCommentLangs: Set<String> = [
        "python", "py", "ruby", "rb", "shell", "sh", "bash", "zsh",
        "yaml", "yml", "toml", "perl", "r", "dockerfile", "makefile"
    ]

    private static let pythonBuiltins: Set<String> = [
        "print", "len", "range", "int", "str", "float", "list", "dict",
        "set", "tuple", "bool", "type", "isinstance", "issubclass",
        "hasattr", "getattr", "setattr", "delattr", "super", "property",
        "classmethod", "staticmethod", "enumerate", "zip", "map", "filter",
        "sorted", "reversed", "abs", "max", "min", "sum", "round", "open",
        "input", "iter", "next", "any", "all", "format", "repr", "hash",
        "id", "callable", "vars", "dir", "help", "hex", "oct", "bin",
        "chr", "ord", "pow", "divmod", "compile", "eval", "exec",
        "globals", "locals", "breakpoint", "object", "Exception",
        "ValueError", "TypeError", "KeyError", "IndexError",
        "AttributeError", "RuntimeError", "StopIteration", "ImportError",
        "FileNotFoundError", "OSError", "IOError", "NotImplementedError"
    ]

    private static let jsBuiltins: Set<String> = [
        "console", "window", "document", "Math", "JSON", "Array",
        "Object", "String", "Number", "Boolean", "Date", "RegExp",
        "Map", "Set", "WeakMap", "WeakSet", "Promise", "Symbol",
        "Proxy", "Reflect", "Error", "TypeError", "RangeError",
        "parseInt", "parseFloat", "isNaN", "isFinite", "setTimeout",
        "setInterval", "clearTimeout", "clearInterval", "fetch",
        "require", "module", "exports", "process", "Buffer",
        "Uint8Array", "Int32Array", "Float64Array", "ArrayBuffer"
    ]

    private static var keywordRegexCache: [String: NSRegularExpression] = [:]
    private static var builtinRegexCache: [String: NSRegularExpression] = [:]

    private static func cachedKeywordRegex(for lang: String) -> NSRegularExpression? {
        if let cached = keywordRegexCache[lang] { return cached }
        let kws = keywords(for: lang)
        guard !kws.isEmpty else { return nil }
        let pattern = "\\b(" + kws.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        keywordRegexCache[lang] = regex
        return regex
    }

    private static func cachedBuiltinRegex(for lang: String) -> NSRegularExpression? {
        if let cached = builtinRegexCache[lang] { return cached }
        let builtins: Set<String>
        switch lang {
        case "python", "py": builtins = pythonBuiltins
        case "javascript", "js", "typescript", "ts", "jsx", "tsx": builtins = jsBuiltins
        default: return nil
        }
        guard !builtins.isEmpty else { return nil }
        let pattern = "\\b(" + builtins.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        builtinRegexCache[lang] = regex
        return regex
    }

    private static func tokenizeGeneric(
        _ code: String, _ range: NSRange, _ lang: String,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        let usesHash = hashCommentLangs.contains(lang)

        if !usesHash {
            addMatches(multiLineCommentRegex, range, code, .comment, &tokens, &occupied)
            addMatches(slashCommentRegex, range, code, .comment, &tokens, &occupied)
        } else {
            addMatches(hashCommentRegex, range, code, .comment, &tokens, &occupied)
        }

        if ["python", "py"].contains(lang) {
            addMatches(tripleDoubleStringRegex, range, code, .string, &tokens, &occupied)
            addMatches(tripleSingleStringRegex, range, code, .string, &tokens, &occupied)
        }

        addMatches(doubleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(singleStringRegex, range, code, .string, &tokens, &occupied)

        if ["javascript", "js", "typescript", "ts", "jsx", "tsx", "swift", "kotlin", "kt"].contains(lang) {
            addMatches(backtickStringRegex, range, code, .string, &tokens, &occupied)
        }

        if ["swift"].contains(lang) {
            addMatches(swiftAttributeRegex, range, code, .attribute, &tokens, &occupied)
        }
        if ["python", "py"].contains(lang) {
            addMatches(pythonDecoratorRegex, range, code, .attribute, &tokens, &occupied)
        }
        if ["shell", "sh", "bash", "zsh"].contains(lang) {
            addMatches(shellVariableRegex, range, code, .variable, &tokens, &occupied)
        }

        addMatches(numberRegex, range, code, .number, &tokens, &occupied)

        if let kwRegex = cachedKeywordRegex(for: lang) {
            addMatches(kwRegex, range, code, .keyword, &tokens, &occupied)
        }

        if let blRegex = cachedBuiltinRegex(for: lang) {
            addMatches(blRegex, range, code, .builtin, &tokens, &occupied)
        }

        addMatches(typeRegex, range, code, .type, &tokens, &occupied)
    }

    private static func tokenizeHTML(
        _ code: String, _ range: NSRange,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        addMatches(htmlCommentRegex, range, code, .comment, &tokens, &occupied)
        addMatches(doubleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(singleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(htmlTagRegex, range, code, .tag, &tokens, &occupied, captureGroup: 1)
        addMatches(htmlAttrRegex, range, code, .property, &tokens, &occupied, captureGroup: 1)
    }

    private static func tokenizeCSS(
        _ code: String, _ range: NSRange,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        addMatches(cssCommentRegex, range, code, .comment, &tokens, &occupied)
        addMatches(doubleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(singleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(cssColorRegex, range, code, .number, &tokens, &occupied)
        addMatches(cssSelectorRegex, range, code, .tag, &tokens, &occupied, captureGroup: 1)
        addMatches(cssPropertyRegex, range, code, .property, &tokens, &occupied, captureGroup: 1)
        addMatches(numberRegex, range, code, .number, &tokens, &occupied)
    }

    private static func tokenizeJSON(
        _ code: String, _ range: NSRange,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        addMatches(jsonKeyRegex, range, code, .property, &tokens, &occupied)
        addMatches(jsonStringRegex, range, code, .string, &tokens, &occupied, captureGroup: 1)
        addMatches(numberRegex, range, code, .number, &tokens, &occupied)
        addMatches(jsonBoolNullRegex, range, code, .keyword, &tokens, &occupied)
    }

    private static func tokenizeMarkdown(
        _ code: String, _ range: NSRange,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        addMatches(mdHeaderRegex, range, code, .keyword, &tokens, &occupied)
        addMatches(mdCodeRegex, range, code, .string, &tokens, &occupied)
        addMatches(mdBoldRegex, range, code, .type, &tokens, &occupied)
        addMatches(mdItalicRegex, range, code, .attribute, &tokens, &occupied)
        addMatches(mdLinkRegex, range, code, .property, &tokens, &occupied)
    }

    private static func tokenizeSQL(
        _ code: String, _ range: NSRange,
        _ tokens: inout [Token], _ occupied: inout IndexSet
    ) {
        addMatches(sqlCommentRegex, range, code, .comment, &tokens, &occupied)
        addMatches(multiLineCommentRegex, range, code, .comment, &tokens, &occupied)
        addMatches(singleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(doubleStringRegex, range, code, .string, &tokens, &occupied)
        addMatches(numberRegex, range, code, .number, &tokens, &occupied)
        addMatches(sqlKeywordRegex, range, code, .keyword, &tokens, &occupied)
        addMatches(typeRegex, range, code, .type, &tokens, &occupied)
    }

    private static func keywords(for lang: String) -> [String] {
        switch lang {
        case "swift":
            return ["func", "var", "let", "if", "else", "for", "while", "return", "class", "struct",
                    "enum", "protocol", "import", "guard", "switch", "case", "break", "continue",
                    "true", "false", "nil", "self", "Self", "private", "public", "internal",
                    "fileprivate", "open", "static", "override", "mutating", "throws", "throw",
                    "try", "catch", "async", "await", "some", "any", "where", "in", "as", "is",
                    "defer", "do", "repeat", "typealias", "extension", "init", "deinit", "subscript",
                    "final", "lazy", "weak", "unowned", "indirect", "inout", "operator",
                    "associatedtype", "convenience", "required", "dynamic", "optional",
                    "precedencegroup", "willSet", "didSet", "get", "set", "rethrows",
                    "consuming", "borrowing", "nonisolated", "isolated", "macro"]
        case "javascript", "js", "jsx":
            return ["function", "const", "let", "var", "if", "else", "for", "while", "return",
                    "class", "new", "this", "typeof", "instanceof", "import", "export", "from",
                    "default", "async", "await", "try", "catch", "throw", "finally", "switch",
                    "case", "break", "continue", "true", "false", "null", "undefined", "void",
                    "yield", "of", "in", "delete", "do", "extends", "super", "static", "get", "set"]
        case "typescript", "ts", "tsx":
            return ["function", "const", "let", "var", "if", "else", "for", "while", "return",
                    "class", "new", "this", "typeof", "instanceof", "import", "export", "from",
                    "default", "async", "await", "try", "catch", "throw", "finally", "switch",
                    "case", "break", "continue", "true", "false", "null", "undefined", "void",
                    "yield", "of", "in", "delete", "do", "extends", "super", "static", "get", "set",
                    "interface", "type", "enum", "implements", "abstract", "as", "is", "namespace",
                    "declare", "readonly", "keyof", "never", "unknown", "any", "satisfies", "infer"]
        case "python", "py":
            return ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
                    "from", "as", "try", "except", "raise", "with", "lambda", "True", "False",
                    "None", "pass", "break", "continue", "and", "or", "not", "in", "is", "global",
                    "nonlocal", "async", "await", "yield", "del", "assert", "finally", "match", "case"]
        case "go":
            return ["func", "var", "const", "if", "else", "for", "range", "return", "type",
                    "struct", "interface", "map", "chan", "go", "select", "case", "break",
                    "continue", "switch", "default", "package", "import", "defer", "fallthrough",
                    "goto", "true", "false", "nil"]
        case "rust", "rs":
            return ["fn", "let", "mut", "if", "else", "for", "while", "loop", "return", "struct",
                    "enum", "impl", "trait", "use", "mod", "pub", "crate", "super", "self", "Self",
                    "match", "break", "continue", "true", "false", "as", "in", "ref", "move",
                    "async", "await", "dyn", "static", "const", "type", "where", "unsafe", "extern"]
        case "java", "kotlin", "kt":
            return ["class", "interface", "enum", "extends", "implements", "import", "package",
                    "public", "private", "protected", "static", "final", "abstract", "new", "this",
                    "super", "if", "else", "for", "while", "do", "switch", "case", "break",
                    "continue", "return", "throw", "throws", "try", "catch", "finally", "void",
                    "true", "false", "null", "instanceof", "val", "var", "fun", "when", "object",
                    "override", "data", "sealed", "companion", "suspend"]
        case "c", "cpp", "c++", "h", "hpp":
            return ["if", "else", "for", "while", "do", "switch", "case", "break", "continue",
                    "return", "struct", "union", "enum", "typedef", "const", "static", "extern",
                    "volatile", "inline", "sizeof", "void", "int", "long", "short", "double",
                    "float", "char", "unsigned", "signed", "auto", "goto", "default", "true",
                    "false", "NULL", "nullptr", "class", "public", "private", "protected",
                    "virtual", "override", "new", "delete", "template", "typename", "namespace",
                    "using", "throw", "try", "catch", "constexpr"]
        case "ruby", "rb":
            return ["def", "class", "module", "if", "elsif", "else", "unless", "for", "while",
                    "until", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "end",
                    "true", "false", "nil", "self", "super", "require", "include", "extend",
                    "private", "public", "protected", "and", "or", "not", "in", "then", "when", "case"]
        case "shell", "sh", "bash", "zsh":
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                    "esac", "function", "return", "exit", "echo", "export", "local", "readonly",
                    "shift", "set", "unset", "source", "true", "false", "in", "select", "until",
                    "cd", "ls", "grep", "sed", "awk", "cat", "chmod", "chown", "cp", "mv", "rm",
                    "mkdir", "rmdir", "find", "xargs", "curl", "wget"]
        case "json", "jsonc":
            return ["true", "false", "null"]
        default:
            return ["if", "else", "for", "while", "do", "switch", "case", "break", "continue",
                    "return", "function", "class", "new", "this", "void", "true", "false", "null",
                    "const", "var", "let", "import", "export", "static", "public", "private",
                    "protected", "try", "catch", "throw", "finally", "async", "await", "from",
                    "default", "yield"]
        }
    }
}
