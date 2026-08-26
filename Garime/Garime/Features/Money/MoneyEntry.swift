import Foundation

enum MoneyKind: String, Codable, CaseIterable, Identifiable {
    case income
    case expense

    var id: String { rawValue }

    var label: String {
        switch self {
        case .income: return "entrada"
        case .expense: return "saída"
        }
    }
}

struct MoneyEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var kind: MoneyKind
    /// Sempre positivo; o sinal vem de `kind`.
    var amount: Decimal
    var category: String
    var note: String
    /// Compromisso que se repete todo mês (aluguel, salário, assinatura).
    var recurring: Bool
    /// FITID do extrato importado: impede lançar duas vezes a mesma transação.
    var externalId: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: MoneyKind,
        amount: Decimal,
        category: String,
        note: String = "",
        recurring: Bool = false,
        externalId: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.amount = amount
        self.category = category
        self.note = note
        self.recurring = recurring
        self.externalId = externalId
    }
}

struct MoneySummary: Equatable {
    var income: Decimal = 0
    var expense: Decimal = 0

    var balance: Decimal { income - expense }
}

/// Projeção honesta: o que já é recorrente conta inteiro, o resto é
/// extrapolado pelo ritmo dos dias já vividos no mês.
struct MoneyProjection: Equatable {
    var realized: MoneySummary
    var projectedIncome: Decimal
    var projectedExpense: Decimal

    var projectedBalance: Decimal { projectedIncome - projectedExpense }
}

enum MoneyMath {
    static func entries(_ entries: [MoneyEntry], inMonthOf date: Date, calendar: Calendar = .current) -> [MoneyEntry] {
        entries.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
    }

    static func summary(of entries: [MoneyEntry]) -> MoneySummary {
        entries.reduce(into: MoneySummary()) { summary, entry in
            switch entry.kind {
            case .income: summary.income += entry.amount
            case .expense: summary.expense += entry.amount
            }
        }
    }

    static func projection(
        for entries: [MoneyEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MoneyProjection {
        let month = self.entries(entries, inMonthOf: now, calendar: calendar)
        let realized = summary(of: month)

        let totalDays = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let elapsedDays = max(1, calendar.component(.day, from: now))
        let pace = Decimal(totalDays) / Decimal(elapsedDays)

        let recurring = summary(of: month.filter(\.recurring))
        let variable = summary(of: month.filter { !$0.recurring })

        return MoneyProjection(
            realized: realized,
            projectedIncome: recurring.income + variable.income * pace,
            projectedExpense: recurring.expense + variable.expense * pace
        )
    }
}

enum MoneyAmount {
    /// Aceita o jeito que se digita no Brasil: "12,50", "1.200,90", "12.50".
    static func parse(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "R$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        if normalized.contains(",") {
            normalized = normalized.replacingOccurrences(of: ".", with: "")
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard normalized.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Decimal(string: normalized),
              value > 0
        else { return nil }
        return value
    }
}

enum MoneyFormat {
    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter
    }()

    static func brl(_ value: Decimal) -> String {
        currency.string(from: value as NSDecimalNumber) ?? "R$ 0,00"
    }

    static func signed(_ value: Decimal) -> String {
        value < 0 ? "-" + brl(-value) : brl(value)
    }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "LLLL"
        return formatter.string(from: date).lowercased()
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }
}
