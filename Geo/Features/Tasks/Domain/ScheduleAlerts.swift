import Foundation

struct ScheduleAlerts: Codable, Hashable {
    var reminders: [ReminderOffset]
    var recurringReminders: [RecurringReminder]
    var firedReminders: [ReminderOffset]
    var smartReminder: Bool
    var snoozedUntil: Date?

    init(
        reminders: [ReminderOffset] = [.atTime],
        recurringReminders: [RecurringReminder] = [],
        firedReminders: [ReminderOffset] = [],
        smartReminder: Bool = false,
        snoozedUntil: Date? = nil
    ) {
        self.reminders = reminders
        self.recurringReminders = recurringReminders
        self.firedReminders = firedReminders
        self.smartReminder = smartReminder
        self.snoozedUntil = snoozedUntil
    }

    static func fromLegacyFields(
        reminders: [ReminderOffset],
        recurringReminders: [RecurringReminder],
        firedReminders: [ReminderOffset],
        smartReminder: Bool,
        snoozedUntil: Date?
    ) -> ScheduleAlerts {
        ScheduleAlerts(
            reminders: reminders,
            recurringReminders: recurringReminders,
            firedReminders: firedReminders,
            smartReminder: smartReminder,
            snoozedUntil: snoozedUntil
        )
    }
}
