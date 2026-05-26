import Foundation

@MainActor
enum WeeklyLogService {
    struct HabitOutcome {
        let title: String
        let hit: Int
        let expected: Int
        let currentStreak: Int
    }

    struct MilestoneSnapshot {
        let title: String
        let progressPercent: Double
        let checkedDelta: Int
    }

    static func ensureLog(
        for weekStart: Date,
        calendar: Calendar = .current,
        environment: AppEnvironment,
        blocksStore: BlocksStore,
        tasksStore: TasksStore,
        tagsStore: TagStore
    ) async -> String? {
        let normalizedStart = calendar.startOfDay(for: weekStart)
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: normalizedStart) else {
            return nil
        }
        let weekNumber = calendar.component(.weekOfYear, from: normalizedStart)
        let expectedTitle = "Semana \(weekNumber)"
        let expectedIdPrefix = "Semana-\(weekNumber)"

        if let existingId = findExistingLog(
            title: expectedTitle,
            idPrefix: expectedIdPrefix,
            blocksStore: blocksStore
        ) {
            return existingId
        }

        let tasks = tasksStore.tasks

        let completed = tasks.filter {
            $0.status == .completed
                && $0.modifiedAt >= normalizedStart
                && $0.modifiedAt < weekEnd
        }

        let carryOver = tasks.filter {
            $0.status == .pending
                && $0.horizon == .week
                && $0.modifiedAt < weekEnd
        }

        let habits = tasks.filter { $0.kind == .habit }
        let habitOutcomes = habits.map { habit -> HabitOutcome in
            let hit = habit.completionHistory.filter {
                $0 >= normalizedStart && $0 < weekEnd
            }.count
            let expected = expectedHabitCount(for: habit.recurrence, calendar: calendar)
            return HabitOutcome(
                title: habit.title,
                hit: hit,
                expected: expected,
                currentStreak: habit.currentStreak
            )
        }

        let milestones = tasks.filter { $0.kind == .milestone && $0.linkedBlockId != nil }
        let milestoneSnapshots = milestones.compactMap { milestone -> MilestoneSnapshot? in
            guard let progress = milestone.milestoneProgress(blocks: blocksStore, allTasks: tasks) else {
                return nil
            }
            return MilestoneSnapshot(
                title: milestone.title,
                progressPercent: progress.percent,
                checkedDelta: 0
            )
        }

        let markdown = composeMarkdown(
            weekStart: normalizedStart,
            weekEnd: weekEnd,
            completed: completed,
            carryOver: carryOver,
            habitOutcomes: habitOutcomes,
            milestones: milestoneSnapshots,
            weekNumber: weekNumber
        )

        do {
            let block = try await environment.blocksRepository.create(
                title: expectedTitle,
                markdown: markdown
            )

            if let tagId = await resolveWeeklyLogTagId(
                environment: environment,
                tagsStore: tagsStore
            ) {
                try? await environment.blocksRepository.setTag(
                    blockId: block.id,
                    tagId: tagId
                )
            }

            try? await environment.dayRepository.addBlockToDay(
                date: normalizedStart,
                blockId: block.id
            )

            return block.id
        } catch {
            return nil
        }
    }

    static func composeMarkdown(
        weekStart: Date,
        weekEnd: Date,
        completed: [TaskItem],
        carryOver: [TaskItem],
        habitOutcomes: [HabitOutcome],
        milestones: [MilestoneSnapshot],
        weekNumber: Int
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let startStr = formatter.string(from: weekStart)
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
        let endStr = formatter.string(from: lastDay)

        var lines: [String] = []
        lines.append("# Semana \(weekNumber) — \(startStr) → \(endStr)")
        lines.append("")

        lines.append("## Done (\(completed.count))")
        if completed.isEmpty {
            lines.append("- _(nothing completed)_")
        } else {
            for task in completed {
                lines.append("- ✅ \(task.title) [\(task.kind.rawValue)]")
            }
        }
        lines.append("")

        lines.append("## Carry-over (\(carryOver.count))")
        if carryOver.isEmpty {
            lines.append("- _(clean slate)_")
        } else {
            for task in carryOver {
                lines.append("- ⏳ \(task.title) → next week")
            }
        }
        lines.append("")

        lines.append("## Habits")
        if habitOutcomes.isEmpty {
            lines.append("- _(no habits tracked)_")
        } else {
            for outcome in habitOutcomes {
                let icon = habitIcon(for: outcome.title)
                let sparkle = outcome.hit == outcome.expected && outcome.expected > 0 ? " ✨" : ""
                lines.append("- \(icon) \(outcome.title): \(outcome.hit)/\(outcome.expected)\(sparkle) streak \(outcome.currentStreak)")
            }
        }
        lines.append("")

        lines.append("## Milestones")
        if milestones.isEmpty {
            lines.append("- _(no milestones linked)_")
        } else {
            for snapshot in milestones {
                let percent = Int((snapshot.progressPercent * 100).rounded())
                lines.append("- \(snapshot.title): \(percent)%")
            }
        }
        lines.append("")

        lines.append("## Notes")
        lines.append("_Space for reflection — edit freely._")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func findExistingLog(
        title: String,
        idPrefix: String,
        blocksStore: BlocksStore
    ) -> String? {
        for block in blocksStore.blocks {
            if block.title == title {
                return block.id
            }
            if block.id.hasPrefix(idPrefix) {
                return block.id
            }
        }
        return nil
    }

    private static func expectedHabitCount(
        for rule: RecurrenceRule,
        calendar: Calendar
    ) -> Int {
        switch rule.type {
        case .daily:
            return 7
        case .weekdays:
            return 5
        case .weekly:
            if let days = rule.selectedWeekdays, !days.isEmpty {
                return days.count
            }
            return 1
        case .biweekly:
            if let days = rule.selectedWeekdays, !days.isEmpty {
                return Int((Double(days.count) / 2.0).rounded())
            }
            return 1
        case .custom:
            let frequency = rule.customFrequency ?? .daily
            let interval = max(1, rule.customInterval ?? 1)
            switch frequency {
            case .daily:
                return max(1, 7 / interval)
            case .weekly:
                return interval == 1 ? 1 : 0
            case .monthly, .yearly:
                return 0
            }
        case .monthly, .yearly, .never:
            return 1
        }
    }

    private static func habitIcon(for title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("read") || lower.contains("ler") {
            return "📖"
        }
        if lower.contains("gym") || lower.contains("exerc") {
            return "💪"
        }
        return "🔁"
    }

    private static func resolveWeeklyLogTagId(
        environment: AppEnvironment,
        tagsStore: TagStore
    ) async -> String? {
        let tagName = "weekly-log"
        do {
            let tags = try await environment.tagsRepository.list()
            if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(tagName) == .orderedSame }) {
                return existing.id
            }
            let color = TagColor(red: 0.33, green: 0.33, blue: 1.0, alpha: 1.0)
            let created = try await environment.tagsRepository.create(name: tagName, color: color)
            return created.id
        } catch {
            return nil
        }
    }
}
