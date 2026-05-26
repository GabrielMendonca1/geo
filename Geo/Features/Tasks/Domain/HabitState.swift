import Foundation

struct CheckboxSnapshot: Codable, Hashable {
    let text: String
    let wasChecked: Bool

    init(text: String, wasChecked: Bool) {
        self.text = text
        self.wasChecked = wasChecked
    }
}

struct HabitOccurrence: Codable, Hashable {
    let date: Date
    let checkboxes: [CheckboxSnapshot]

    init(date: Date, checkboxes: [CheckboxSnapshot] = []) {
        self.date = date
        self.checkboxes = checkboxes
    }
}

struct HabitState: Codable, Hashable {
    var occurrences: [HabitOccurrence]
    var currentStreak: Int
    var longestStreak: Int
    var resetCheckboxesOnComplete: Bool

    init(
        occurrences: [HabitOccurrence] = [],
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        resetCheckboxesOnComplete: Bool = true
    ) {
        self.occurrences = occurrences
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.resetCheckboxesOnComplete = resetCheckboxesOnComplete
    }

    var completionHistory: [Date] { occurrences.map(\.date) }

    static func fromLegacyFields(
        kind: TaskKind,
        completionHistory: [Date],
        currentStreak: Int,
        longestStreak: Int
    ) -> HabitState? {
        guard kind == .habit else { return nil }
        return HabitState(
            occurrences: completionHistory.map { HabitOccurrence(date: $0, checkboxes: []) },
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            resetCheckboxesOnComplete: true
        )
    }
}
