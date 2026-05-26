import Foundation

struct Day: Identifiable, Codable, Hashable {
    let id: String
    let date: Date
    var blockIds: [String]
    var captureIds: [UUID]

    init(date: Date, blockIds: [String] = [], captureIds: [UUID] = []) {
        self.date = Calendar.current.startOfDay(for: date)
        self.id = Day.idFromDate(self.date)
        self.blockIds = blockIds
        self.captureIds = captureIds
    }

    private static var idFormatter: DateFormatter { DateFormatters.dayId }

    static func idFromDate(_ date: Date) -> String {
        idFormatter.string(from: date)
    }
}
