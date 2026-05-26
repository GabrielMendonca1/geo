import Foundation

enum HolidayCountry: String, CaseIterable, Codable {
    case brazil = "BR"
    case usa = "US"
}

struct Holiday: Identifiable, Hashable {
    let id: String
    let name: String
    let startDate: Date
    let endDate: Date?
    let country: HolidayCountry

    var isMultiDay: Bool {
        guard let endDate else { return false }
        return !Calendar.current.isDate(startDate, inSameDayAs: endDate)
    }
}
