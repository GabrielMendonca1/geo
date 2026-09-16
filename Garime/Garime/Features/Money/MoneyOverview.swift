import Foundation

/// O que a aba mostra: só gastos, só entradas ou tudo junto.
enum MoneyScope: String, CaseIterable, Identifiable {
    case expense
    case income
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .expense: return "Gastos"
        case .income: return "Entradas"
        case .all: return "Tudo"
        }
    }

    var totalLabel: String {
        switch self {
        case .expense: return "Gasto total"
        case .income: return "Entrada total"
        case .all: return "Saldo"
        }
    }

    func includes(_ entry: MoneyEntry) -> Bool {
        switch self {
        case .expense: return entry.kind == .expense
        case .income: return entry.kind == .income
        case .all: return true
        }
    }

    /// Valor com sinal para somar no escopo: em "Tudo" entrada soma e gasto subtrai.
    func signedAmount(of entry: MoneyEntry) -> Decimal {
        switch self {
        case .expense, .income: return entry.amount
        case .all: return entry.kind == .income ? entry.amount : -entry.amount
        }
    }
}

struct MoneyWeekDay: Equatable, Identifiable {
    var date: Date
    var label: String
    var total: Decimal

    var id: Date { date }
}

struct MoneyWeek: Equatable {
    var days: [MoneyWeekDay]

    var total: Decimal { days.reduce(0) { $0 + $1.total } }

    /// Teto do gráfico arredondado para um passo "bonito" (20, 50, 100, 200…).
    var axisMax: Decimal {
        let peak = days.map { abs($0.total) }.max() ?? 0
        return MoneyWeek.niceCeiling(peak)
    }

    var axisTicks: [Decimal] {
        let top = axisMax
        return (0...4).map { top / 4 * Decimal($0) }
    }

    static func niceCeiling(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 80 }
        let steps: [Decimal] = [20, 40, 80, 100, 200, 400, 800, 1000, 2000, 4000, 8000, 10000, 20000, 40000, 80000, 100000]
        if let step = steps.first(where: { $0 >= value }) { return step }
        var magnitude: Decimal = 100000
        while magnitude < value { magnitude *= 10 }
        return magnitude
    }
}

enum MoneyOverview {
    /// Semana corrente (domingo a sábado) com o total por dia no escopo.
    static func week(
        _ entries: [MoneyEntry],
        scope: MoneyScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MoneyWeek {
        var cal = calendar
        cal.firstWeekday = 1
        let startOfToday = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: startOfToday)
        guard let start = cal.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) else {
            return MoneyWeek(days: [])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEE"

        let days = (0..<7).compactMap { offset -> MoneyWeekDay? in
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let total = entries
                .filter { scope.includes($0) && cal.isDate($0.date, inSameDayAs: day) }
                .reduce(Decimal(0)) { $0 + scope.signedAmount(of: $1) }
            let raw = formatter.string(from: day).replacingOccurrences(of: ".", with: "")
            return MoneyWeekDay(date: day, label: raw.prefix(3).capitalized, total: total)
        }
        return MoneyWeek(days: days)
    }

    struct DayGroup: Equatable, Identifiable {
        var day: Date
        var title: String
        var entries: [MoneyEntry]

        var id: Date { day }
    }

    /// Agrupa por dia, do mais novo ao mais antigo. O grupo mais recente vira
    /// "Recentes"; os outros levam o nome do dia da semana ou a data.
    static func groups(
        _ entries: [MoneyEntry],
        scope: MoneyScope,
        query: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = entries.filter { entry in
            guard scope.includes(entry) else { return false }
            guard !needle.isEmpty else { return true }
            return entry.category.lowercased().contains(needle) || entry.note.lowercased().contains(needle)
        }
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted(by: >)

        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "pt_BR")
        weekday.dateFormat = "EEEE"
        let full = DateFormatter()
        full.locale = Locale(identifier: "pt_BR")
        full.dateFormat = "d MMM yyyy"

        return days.enumerated().map { index, day in
            let title: String
            if index == 0 {
                title = "Recentes"
            } else if let daysAgo = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day,
                      daysAgo < 7 {
                title = weekday.string(from: day)
                    .components(separatedBy: "-").first?.capitalized ?? full.string(from: day)
            } else {
                title = full.string(from: day).replacingOccurrences(of: ".", with: "")
            }
            let sorted = (byDay[day] ?? []).sorted { $0.date > $1.date }
            return DayGroup(day: day, title: title, entries: sorted)
        }
    }

    static func title(for entry: MoneyEntry) -> String {
        let note = entry.note.trimmingCharacters(in: .whitespaces)
        return (note.isEmpty ? entry.category : note).capitalizedFirst
    }

    static func subtitle(for entry: MoneyEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: entry.date).replacingOccurrences(of: ".", with: "")
    }

    static func symbol(for entry: MoneyEntry) -> String {
        switch entry.category.lowercased() {
        case "mercado": return "cart.fill"
        case "comida": return "fork.knife"
        case "transporte": return "car.fill"
        case "casa": return "house.fill"
        case "saúde", "saude": return "cross.case.fill"
        case "academia": return "dumbbell.fill"
        case "lazer": return "gamecontroller.fill"
        case "assinatura": return "music.note"
        case "salário", "salario": return "banknote.fill"
        case "freela": return "laptopcomputer"
        case "reembolso": return "arrow.uturn.backward"
        case "investimento": return "chart.line.uptrend.xyaxis"
        default: return entry.kind == .income ? "arrow.down.left" : "creditcard.fill"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
