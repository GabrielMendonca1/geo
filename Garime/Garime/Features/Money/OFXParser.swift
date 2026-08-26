import Foundation

/// Lê o extrato OFX que o Santander (e qualquer banco) exporta.
/// OFX é SGML: as tags de valor não fecham, então parser de XML não serve.
enum OFXParser {
    struct Transaction: Equatable {
        var fitid: String?
        var date: Date
        /// Negativo é saída, positivo é entrada — como o banco escreve.
        var amount: Decimal
        var memo: String
    }

    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // Extratos brasileiros costumam vir em latin-1.
        return String(data: data, encoding: .isoLatin1)
    }

    static func parse(_ data: Data, calendar: Calendar = .current) -> [Transaction] {
        guard let text = decode(data) else { return [] }
        return parse(text: text, calendar: calendar)
    }

    static func parse(text: String, calendar: Calendar = .current) -> [Transaction] {
        let blocks = text.components(separatedBy: "<STMTTRN>").dropFirst()
        return blocks.compactMap { block -> Transaction? in
            let body = block.components(separatedBy: "</STMTTRN>").first ?? block
            guard let rawDate = value(of: "DTPOSTED", in: body),
                  let date = date(from: rawDate, calendar: calendar),
                  let rawAmount = value(of: "TRNAMT", in: body),
                  let amount = amount(from: rawAmount)
            else { return nil }

            let memo = value(of: "MEMO", in: body) ?? value(of: "NAME", in: body) ?? ""
            return Transaction(
                fitid: value(of: "FITID", in: body),
                date: date,
                amount: amount,
                memo: memo.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Em SGML o valor vai do fim da tag até o próximo '<' ou quebra de linha.
    static func value(of tag: String, in body: String) -> String? {
        guard let range = body.range(of: "<\(tag)>") else { return nil }
        let rest = body[range.upperBound...]
        let raw = rest.prefix { $0 != "<" && $0 != "\n" && $0 != "\r" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Formatos vistos: 20260815, 20260815120000, 20260815120000[-3:BRT]
    static func date(from raw: String, calendar: Calendar = .current) -> Date? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let year = Int(digits.prefix(4))
        let month = Int(digits.dropFirst(4).prefix(2))
        let day = Int(digits.dropFirst(6).prefix(2))
        guard let year, let month, let day else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    static func amount(from raw: String) -> Decimal? {
        var normalized = raw.replacingOccurrences(of: " ", with: "")
        if normalized.contains(",") {
            normalized = normalized.replacingOccurrences(of: ".", with: "")
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }
}

/// Chuta a categoria pelo texto do extrato. É palpite: o usuário corrige depois.
enum MoneyCategoryGuess {
    private static let rules: [(needles: [String], category: String)] = [
        (["ifood", "rappi", "restaurante", "lanchonete", "padaria", "burger", "pizza"], "comida"),
        (["mercado", "supermerc", "atacad", "hortifruti", "carrefour", "pao de acucar", "assai"], "mercado"),
        (["uber", "99app", "99 app", "posto", "combustivel", "shell", "ipiranga", "metro", "onibus"], "transporte"),
        (["drogaria", "farmacia", "droga raia", "drogasil", "hospital", "clinica", "laborator"], "saúde"),
        (["smart fit", "smartfit", "academia", "gym", "bluefit"], "academia"),
        (["netflix", "spotify", "youtube", "icloud", "apple.com", "amazon prime", "assinatura", "hbo", "disney"], "assinatura"),
        (["aluguel", "condominio", "energia", "enel", "light", "sabesp", "agua", "vivo", "claro", "tim ", "internet"], "casa"),
        (["cinema", "bar ", "ingresso", "show", "steam", "playstation"], "lazer"),
        (["salario", "salário", "pagamento de salario", "provento"], "salário"),
        (["reembolso", "estorno", "devolucao"], "reembolso"),
        (["rendimento", "dividendo", "juros", "aplicacao", "resgate"], "investimento"),
    ]

    static func category(for memo: String, kind: MoneyKind) -> String {
        let haystack = memo.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR")).lowercased()
        for rule in rules {
            let matched = rule.needles.contains { needle in
                haystack.contains(needle.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR")).lowercased())
            }
            guard matched else { continue }
            if MoneyCategories.options(for: kind).contains(rule.category) { return rule.category }
        }
        return "outro"
    }
}

enum MoneyImport {
    /// Converte o extrato em lançamentos. O sinal do banco define entrada ou saída.
    static func entries(from transactions: [OFXParser.Transaction]) -> [MoneyEntry] {
        transactions.map { transaction in
            let isExpense = transaction.amount < 0
            let kind: MoneyKind = isExpense ? .expense : .income
            let absolute = isExpense ? -transaction.amount : transaction.amount
            return MoneyEntry(
                date: transaction.date,
                kind: kind,
                amount: absolute,
                category: MoneyCategoryGuess.category(for: transaction.memo, kind: kind),
                note: transaction.memo,
                recurring: false,
                externalId: transaction.fitid
            )
        }
    }
}
