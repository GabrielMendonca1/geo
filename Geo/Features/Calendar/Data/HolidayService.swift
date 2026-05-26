import Foundation

protocol HolidayServiceProviding: Sendable {
    func holidays(for year: Int, countries: [HolidayCountry]) -> [Holiday]
}

final class HolidayService: HolidayServiceProviding, @unchecked Sendable {
    static let shared = HolidayService()

    private let calendar = Calendar.current

    func holidays(for year: Int, countries: [HolidayCountry] = [.brazil, .usa]) -> [Holiday] {
        var result: [Holiday] = []

        for country in countries {
            switch country {
            case .brazil:
                result.append(contentsOf: brazilianHolidays(for: year))
            case .usa:
                result.append(contentsOf: americanHolidays(for: year))
            }
        }

        return result.sorted { $0.startDate < $1.startDate }
    }

    private func brazilianHolidays(for year: Int) -> [Holiday] {
        var holidays: [Holiday] = []

        holidays.append(fixedHoliday("br-ano-novo", "Ano Novo", year: year, month: 1, day: 1, country: .brazil))
        holidays.append(fixedHoliday("br-tiradentes", "Tiradentes", year: year, month: 4, day: 21, country: .brazil))
        holidays.append(fixedHoliday("br-trabalho", "Dia do Trabalho", year: year, month: 5, day: 1, country: .brazil))
        holidays.append(fixedHoliday("br-independencia", "Independência do Brasil", year: year, month: 9, day: 7, country: .brazil))
        holidays.append(fixedHoliday("br-nossa-senhora", "Nossa Senhora Aparecida", year: year, month: 10, day: 12, country: .brazil))
        holidays.append(fixedHoliday("br-finados", "Finados", year: year, month: 11, day: 2, country: .brazil))
        holidays.append(fixedHoliday("br-proclamacao", "Proclamação da República", year: year, month: 11, day: 15, country: .brazil))
        holidays.append(fixedHoliday("br-natal", "Natal", year: year, month: 12, day: 25, country: .brazil))

        if let easter = easterDate(for: year),
           let carnivalStart = calendar.date(byAdding: .day, value: -50, to: easter),
           let carnivalEnd = calendar.date(byAdding: .day, value: -47, to: easter) {
            holidays.append(Holiday(
                id: "br-carnaval-\(year)",
                name: "Carnaval",
                startDate: carnivalStart,
                endDate: carnivalEnd,
                country: .brazil
            ))

            if let goodFriday = calendar.date(byAdding: .day, value: -2, to: easter) {
                holidays.append(Holiday(
                    id: "br-sexta-santa-\(year)",
                    name: "Sexta-feira Santa",
                    startDate: goodFriday,
                    endDate: nil,
                    country: .brazil
                ))
            }

            holidays.append(Holiday(
                id: "br-pascoa-\(year)",
                name: "Páscoa",
                startDate: easter,
                endDate: nil,
                country: .brazil
            ))

            if let corpusChristi = calendar.date(byAdding: .day, value: 60, to: easter) {
                holidays.append(Holiday(
                    id: "br-corpus-christi-\(year)",
                    name: "Corpus Christi",
                    startDate: corpusChristi,
                    endDate: nil,
                    country: .brazil
                ))
            }
        }

        return holidays
    }

    private func americanHolidays(for year: Int) -> [Holiday] {
        var holidays: [Holiday] = []

        holidays.append(fixedHoliday("us-new-year", "New Year's Day", year: year, month: 1, day: 1, country: .usa))
        holidays.append(fixedHoliday("us-independence", "Independence Day", year: year, month: 7, day: 4, country: .usa))
        holidays.append(fixedHoliday("us-veterans", "Veterans Day", year: year, month: 11, day: 11, country: .usa))
        holidays.append(fixedHoliday("us-christmas", "Christmas Day", year: year, month: 12, day: 25, country: .usa))

        if let mlkDay = nthWeekdayOfMonth(nth: 3, weekday: .monday, month: 1, year: year) {
            holidays.append(Holiday(
                id: "us-mlk-\(year)",
                name: "Martin Luther King Jr. Day",
                startDate: mlkDay,
                endDate: nil,
                country: .usa
            ))
        }

        if let presidentsDay = nthWeekdayOfMonth(nth: 3, weekday: .monday, month: 2, year: year) {
            holidays.append(Holiday(
                id: "us-presidents-\(year)",
                name: "Presidents' Day",
                startDate: presidentsDay,
                endDate: nil,
                country: .usa
            ))
        }

        if let memorialDay = lastWeekdayOfMonth(weekday: .monday, month: 5, year: year) {
            holidays.append(Holiday(
                id: "us-memorial-\(year)",
                name: "Memorial Day",
                startDate: memorialDay,
                endDate: nil,
                country: .usa
            ))
        }

        if let laborDay = nthWeekdayOfMonth(nth: 1, weekday: .monday, month: 9, year: year) {
            holidays.append(Holiday(
                id: "us-labor-\(year)",
                name: "Labor Day",
                startDate: laborDay,
                endDate: nil,
                country: .usa
            ))
        }

        if let columbusDay = nthWeekdayOfMonth(nth: 2, weekday: .monday, month: 10, year: year) {
            holidays.append(Holiday(
                id: "us-columbus-\(year)",
                name: "Columbus Day",
                startDate: columbusDay,
                endDate: nil,
                country: .usa
            ))
        }

        if let thanksgiving = nthWeekdayOfMonth(nth: 4, weekday: .thursday, month: 11, year: year) {
            holidays.append(Holiday(
                id: "us-thanksgiving-\(year)",
                name: "Thanksgiving Day",
                startDate: thanksgiving,
                endDate: nil,
                country: .usa
            ))
        }

        return holidays
    }

    private func fixedHoliday(_ id: String, _ name: String, year: Int, month: Int, day: Int, country: HolidayCountry) -> Holiday {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let date = calendar.date(from: components) ?? Date()
        return Holiday(id: "\(id)-\(year)", name: name, startDate: date, endDate: nil, country: country)
    }

    private func nthWeekdayOfMonth(nth: Int, weekday: Weekday, month: Int, year: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.weekday = weekday.calendarValue
        components.weekdayOrdinal = nth
        return calendar.date(from: components)
    }

    private func lastWeekdayOfMonth(weekday: Weekday, month: Int, year: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month + 1
        components.day = 0
        guard let lastDayOfMonth = calendar.date(from: components) else { return nil }

        let lastDayWeekday = calendar.component(.weekday, from: lastDayOfMonth)
        let targetWeekday = weekday.calendarValue
        var daysToSubtract = lastDayWeekday - targetWeekday
        if daysToSubtract < 0 {
            daysToSubtract += 7
        }
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: lastDayOfMonth)
    }

    private func easterDate(for year: Int) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private enum Weekday {
        case sunday, monday, tuesday, wednesday, thursday, friday, saturday

        var calendarValue: Int {
            switch self {
            case .sunday: return 1
            case .monday: return 2
            case .tuesday: return 3
            case .wednesday: return 4
            case .thursday: return 5
            case .friday: return 6
            case .saturday: return 7
            }
        }
    }
}
