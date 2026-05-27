import Foundation

enum TaskTools {
    static func register(tasks: any TasksRepository) -> [MCPRegisteredTool] {
        [
            listTasks(tasks),
            getTask(tasks),
            createTask(tasks),
            updateTask(tasks),
            deleteTask(tasks),
            completeTask(tasks),
            listTasksForDay(tasks),
            listUpcoming(tasks),
            recordHabitOccurrence(tasks),
            addReminder(tasks),
        ]
    }

    // MARK: - Serialization

    private static func bodyDict(_ body: TaskBody) -> [String: AnyCodableValue] {
        let iso = DateFormatters.iso8601
        switch body {
        case .task(let due, let est):
            var d: [String: AnyCodableValue] = [
                "kind": .string("task"),
                "due": .string(iso.string(from: due)),
            ]
            if let est { d["estimated_minutes"] = .int(est) }
            return d
        case .event(let start, let end):
            return [
                "kind": .string("event"),
                "start": .string(iso.string(from: start)),
                "end": .string(iso.string(from: end)),
            ]
        case .habit(let rule, let timeOfDay, let occurrences):
            return [
                "kind": .string("habit"),
                "recurrence": .string(rule.type.rawValue),
                "time_of_day": .string(iso.string(from: timeOfDay)),
                "occurrences": .array(occurrences.map { .string(iso.string(from: $0)) }),
            ]
        case .milestone(let target):
            return [
                "kind": .string("milestone"),
                "target": .string(iso.string(from: target)),
            ]
        }
    }

    private static func reminderDict(_ reminder: Reminder) -> [String: AnyCodableValue] {
        switch reminder.trigger {
        case .offset(let offset):
            return [
                "id": .string(reminder.id.uuidString),
                "trigger": .string("offset"),
                "offset": .string(offset.rawValue),
                "fired": .bool(reminder.fired),
            ]
        case .absolute(let date):
            return [
                "id": .string(reminder.id.uuidString),
                "trigger": .string("absolute"),
                "at": .string(DateFormatters.iso8601.string(from: date)),
                "fired": .bool(reminder.fired),
            ]
        }
    }

    private static func taskSummary(_ task: TaskItem) -> [String: AnyCodableValue] {
        var entry: [String: AnyCodableValue] = [
            "id": .string(task.id),
            "title": .string(task.title),
            "status": .string(task.status.rawValue),
            "kind": .string(task.kind.rawValue),
            "priority": .string(task.priority.rawValue),
            "anchor": .string(DateFormatters.iso8601.string(from: task.anchorDate)),
        ]
        if let blockId = task.linkedBlockId {
            entry["linked_block_id"] = .string(blockId)
        }
        return entry
    }

    private static func taskDetail(_ task: TaskItem) -> [String: AnyCodableValue] {
        let iso = DateFormatters.iso8601
        var result: [String: AnyCodableValue] = [
            "id": .string(task.id),
            "title": .string(task.title),
            "notes": .string(task.notes),
            "status": .string(task.status.rawValue),
            "priority": .string(task.priority.rawValue),
            "created_at": .string(iso.string(from: task.createdAt)),
            "modified_at": .string(iso.string(from: task.modifiedAt)),
            "body": .object(bodyDict(task.body)),
            "reminders": .array(task.reminders.map { .object(reminderDict($0)) }),
        ]
        if let blockId = task.linkedBlockId { result["linked_block_id"] = .string(blockId) }
        if !task.tagIds.isEmpty { result["tag_ids"] = .array(task.tagIds.map { .string($0) }) }
        if let est = task.estimatedMinutes { result["estimated_minutes"] = .int(est) }
        if task.isHabit {
            result["current_streak"] = .int(task.habitCurrentStreak)
            result["longest_streak"] = .int(task.habitLongestStreak)
        }
        return result
    }

    // MARK: - Body parsing from args

    private struct BodyParseFailure: Error { let message: String }

    private static func parseBody(_ args: [String: AnyCodableValue]) throws -> TaskBody {
        guard let bodyObj = args["body"]?.objectValue,
              let kindStr = bodyObj["kind"]?.stringValue else {
            throw BodyParseFailure(message: "Missing required parameter: body.kind")
        }
        let iso = DateFormatters.iso8601
        switch kindStr {
        case "task":
            guard let dueStr = bodyObj["due"]?.stringValue, let due = iso.date(from: dueStr) else {
                throw BodyParseFailure(message: "task body requires due (ISO 8601 UTC)")
            }
            let est = bodyObj["estimated_minutes"]?.intValue
            return .task(due: due, estimatedMinutes: est)
        case "event":
            guard let startStr = bodyObj["start"]?.stringValue, let start = iso.date(from: startStr),
                  let endStr = bodyObj["end"]?.stringValue, let end = iso.date(from: endStr) else {
                throw BodyParseFailure(message: "event body requires start and end (ISO 8601 UTC)")
            }
            return .event(start: start, end: max(end, start))
        case "habit":
            guard let recStr = bodyObj["recurrence"]?.stringValue,
                  let ruleType = RecurrenceRule.RuleType(rawValue: recStr) else {
                throw BodyParseFailure(message: "habit body requires recurrence (daily, weekdays, weekly, biweekly, monthly, yearly)")
            }
            guard let todStr = bodyObj["time_of_day"]?.stringValue, let tod = iso.date(from: todStr) else {
                throw BodyParseFailure(message: "habit body requires time_of_day (ISO 8601 UTC)")
            }
            let weekdays = bodyObj["selected_weekdays"]?.arrayValue?.compactMap(\.intValue)
            let rule = RecurrenceRule(type: ruleType, selectedWeekdays: weekdays)
            return .habit(rule: rule, timeOfDay: tod, occurrences: [])
        case "milestone":
            guard let targetStr = bodyObj["target"]?.stringValue, let target = iso.date(from: targetStr) else {
                throw BodyParseFailure(message: "milestone body requires target (ISO 8601 UTC)")
            }
            return .milestone(target: target)
        default:
            throw BodyParseFailure(message: "Unknown body.kind: \(kindStr)")
        }
    }

    private static let bodyProperties: [String: JSONSchemaProperty] = [
        "kind": .string("Body kind", enum: TaskKind.allCases.map(\.rawValue)),
        "due": .string("ISO 8601 — for kind=task"),
        "estimated_minutes": .integer("Estimated minutes — for kind=task (optional)"),
        "start": .string("ISO 8601 — for kind=event"),
        "end": .string("ISO 8601 — for kind=event"),
        "recurrence": .string("Rule type — for kind=habit", enum: ["daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]),
        "time_of_day": .string("ISO 8601 — for kind=habit"),
        "selected_weekdays": .array("Weekdays 1=Sun..7=Sat — for kind=habit (optional)", items: .integer()),
        "target": .string("ISO 8601 — for kind=milestone"),
    ]

    // MARK: - Window helpers

    private static func parseWindowHours(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return 24 }
        if raw == "24h" { return 24 }
        if raw == "7d" { return 24 * 7 }
        if raw == "30d" { return 24 * 30 }
        if raw.hasSuffix("h"), let n = Int(raw.dropLast()), n > 0 { return n }
        if raw.hasSuffix("d"), let n = Int(raw.dropLast()), n > 0 { return n * 24 }
        if let n = Int(raw), n > 0 { return n }
        return 24
    }

    private static func resolveKinds(_ args: [String: AnyCodableValue]) -> Set<TaskKind> {
        guard let values = args["kinds"]?.arrayValue, !values.isEmpty else {
            return Set(TaskKind.allCases)
        }
        let parsed = values.compactMap { $0.stringValue.flatMap(TaskKind.init(rawValue:)) }
        return parsed.isEmpty ? Set(TaskKind.allCases) : Set(parsed)
    }

    private static func occursOnDay(task: TaskItem, dayStart: Date, dayEnd: Date, calendar: Calendar) -> Bool {
        if case .habit(let rule, _, _) = task.body {
            var cursor = task.body.anchorDate
            var safety = 0
            while cursor <= dayEnd, safety < 4000 {
                if cursor >= dayStart { return true }
                guard let next = rule.nextDate(after: cursor, calendar: calendar) else { return false }
                if next <= cursor { return false }
                cursor = next
                safety += 1
            }
            return false
        }
        let anchor = task.anchorDate
        return anchor >= dayStart && anchor < dayEnd
    }

    private static func firstOccurrence(task: TaskItem, in range: Range<Date>, calendar: Calendar) -> Date? {
        if case .habit(let rule, _, _) = task.body {
            var cursor = task.body.anchorDate
            var safety = 0
            while cursor < range.upperBound, safety < 4000 {
                if cursor >= range.lowerBound { return cursor }
                guard let next = rule.nextDate(after: cursor, calendar: calendar) else { return nil }
                if next <= cursor { return nil }
                cursor = next
                safety += 1
            }
            return nil
        }
        let anchor = task.anchorDate
        return (anchor >= range.lowerBound && anchor < range.upperBound) ? anchor : nil
    }

    // MARK: - Tools

    private static func listTasks(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_tasks",
            description: "List tasks. Optionally filter by status, linked block, kind, or priority.",
            schema: JSONSchemaObject(properties: [
                "status": .string("Filter by status", enum: ["pending", "completed"]),
                "linked_block_id": .string("Filter by linked block ID"),
                "kind": .string("Filter by kind", enum: TaskKind.allCases.map(\.rawValue)),
                "priority": .string("Filter by priority", enum: TaskPriority.allCases.map(\.rawValue)),
            ]),
            handler: { args in
                var items = try await tasks.list()
                if let status = args["status"]?.stringValue, let s = TaskStatus(rawValue: status) {
                    items = items.filter { $0.status == s }
                }
                if let blockId = args["linked_block_id"]?.stringValue {
                    items = items.filter { $0.linkedBlockId == blockId }
                }
                if let kind = args["kind"]?.stringValue, let k = TaskKind(rawValue: kind) {
                    items = items.filter { $0.kind == k }
                }
                if let priority = args["priority"]?.stringValue, let p = TaskPriority(rawValue: priority) {
                    items = items.filter { $0.priority == p }
                }
                return .json(items.map(taskSummary))
            }
        ).registered
    }

    private static func getTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_task",
            description: "Get a task's full details by ID.",
            schema: JSONSchemaObject(properties: ["id": .string("Task UUID")], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                let all = try await tasks.list()
                guard let task = all.first(where: { $0.id == id }) else {
                    return .error("Task not found: \(id)")
                }
                return .json(taskDetail(task))
            }
        ).registered
    }

    private static func createTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "create_task",
            description: "Create a task. Required: title, body (with kind=task|event|habit|milestone and its fields).",
            schema: JSONSchemaObject(properties: [
                "title": .string("Task title"),
                "body": .object("Body — shape depends on kind", properties: bodyProperties, required: ["kind"]),
                "notes": .string("Task notes"),
                "linked_block_id": .string("Block ID to link"),
                "priority": .string("Task priority", enum: TaskPriority.allCases.map(\.rawValue)),
                "tag_ids": .array("Tag IDs", items: .string()),
                "reminders": .array("Reminders to attach", items: .object(nil, properties: [
                    "trigger": .string("offset or absolute", enum: ["offset", "absolute"]),
                    "offset": .string("ReminderOffset rawValue (when trigger=offset)", enum: ReminderOffset.allCases.map(\.rawValue)),
                    "at": .string("ISO 8601 (when trigger=absolute)"),
                ], required: ["trigger"])),
            ], required: ["title", "body"]),
            handler: { args in
                guard let title = args["title"]?.stringValue else {
                    return .error("Missing required parameter: title")
                }
                let body: TaskBody
                do { body = try parseBody(args) }
                catch let e as BodyParseFailure { return .error(e.message) }
                catch { return .error(error.localizedDescription) }
                var priority: TaskPriority = .unset
                if let priStr = args["priority"]?.stringValue, let p = TaskPriority(rawValue: priStr) { priority = p }
                let tagIds = args["tag_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let reminders = parseReminders(args["reminders"]?.arrayValue) ?? [.atTime()]

                let draft = TaskDraft(
                    title: title,
                    notes: args["notes"]?.stringValue ?? "",
                    linkedBlockId: args["linked_block_id"]?.stringValue,
                    priority: priority,
                    tagIds: tagIds,
                    body: body,
                    reminders: reminders
                )
                let task = try await tasks.create(draft)
                return .json(["id": task.id, "title": task.title])
            }
        ).registered
    }

    private static func parseReminders(_ raw: [AnyCodableValue]?) -> [Reminder]? {
        guard let raw else { return nil }
        var out: [Reminder] = []
        let iso = DateFormatters.iso8601
        for v in raw {
            guard let obj = v.objectValue, let trig = obj["trigger"]?.stringValue else { continue }
            if trig == "offset", let offRaw = obj["offset"]?.stringValue, let off = ReminderOffset(rawValue: offRaw) {
                out.append(Reminder(trigger: .offset(off)))
            } else if trig == "absolute", let atStr = obj["at"]?.stringValue, let date = iso.date(from: atStr) {
                out.append(Reminder(trigger: .absolute(date)))
            }
        }
        return out
    }

    private static func updateTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "update_task",
            description: "Update task fields. Pass only fields you want to change. To change schedule/recurrence, pass a full new body.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
                "title": .string("New title"),
                "notes": .string("New notes"),
                "status": .string("New status", enum: ["pending", "completed"]),
                "linked_block_id": .string("Block ID to link"),
                "priority": .string("New priority", enum: TaskPriority.allCases.map(\.rawValue)),
                "tag_ids": .array("New tag IDs", items: .string()),
                "body": .object("Replacement body (preserves habit occurrences if same kind)", properties: bodyProperties),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                let all = try await tasks.list()
                guard var task = all.first(where: { $0.id == id }) else { return .error("Task not found: \(id)") }

                if let title = args["title"]?.stringValue { task.title = title }
                if let notes = args["notes"]?.stringValue { task.notes = notes }
                if let status = args["status"]?.stringValue, let s = TaskStatus(rawValue: status) { task.status = s }
                if let blockId = args["linked_block_id"]?.stringValue { task.linkedBlockId = blockId }
                if let priStr = args["priority"]?.stringValue, let p = TaskPriority(rawValue: priStr) { task.priority = p }
                if let tagValues = args["tag_ids"]?.arrayValue { task.tagIds = tagValues.compactMap(\.stringValue) }
                if args["body"]?.objectValue != nil {
                    do {
                        let newBody = try parseBody(args)
                        if case .habit(_, _, let oldOccs) = task.body, case .habit(let rule, let tod, _) = newBody {
                            task.body = .habit(rule: rule, timeOfDay: tod, occurrences: oldOccs)
                        } else {
                            task.body = newBody
                        }
                    } catch let e as BodyParseFailure { return .error(e.message) }
                    catch { return .error(error.localizedDescription) }
                }
                task.modifiedAt = Date()
                try await tasks.update(task)
                return .json(["success": .bool(true)])
            }
        ).registered
    }

    private static func deleteTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "delete_task",
            description: "Delete a task by ID.",
            schema: JSONSchemaObject(properties: ["id": .string("Task UUID")], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                try await tasks.delete(id: id)
                return .json(["success": .bool(true)])
            }
        ).registered
    }

    private static func completeTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "complete_task",
            description: "Mark a one-shot task or event as completed. For habits, use record_habit_occurrence.",
            schema: JSONSchemaObject(properties: ["id": .string("Task UUID")], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                let all = try await tasks.list()
                guard var task = all.first(where: { $0.id == id }) else { return .error("Task not found: \(id)") }
                if task.isHabit {
                    return .error("This is a habit; call record_habit_occurrence instead.")
                }
                task.status = .completed
                task.modifiedAt = Date()
                try await tasks.update(task)
                return .json(["success": .bool(true)])
            }
        ).registered
    }

    private static func recordHabitOccurrence(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "record_habit_occurrence",
            description: "Log a habit occurrence (default: now). Updates streaks.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Habit task UUID"),
                "date": .string("ISO 8601 occurrence date (defaults to now)"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                let all = try await tasks.list()
                guard var task = all.first(where: { $0.id == id }) else { return .error("Task not found: \(id)") }
                guard case .habit(let rule, let tod, var occurrences) = task.body else {
                    return .error("Task is not a habit")
                }
                let when: Date
                if let dStr = args["date"]?.stringValue, let parsed = DateFormatters.iso8601.date(from: dStr) {
                    when = parsed
                } else {
                    when = Date()
                }
                let cal = Calendar.current
                if !occurrences.contains(where: { cal.isDate($0, inSameDayAs: when) }) {
                    occurrences.append(when)
                }
                task.body = .habit(rule: rule, timeOfDay: tod, occurrences: occurrences)
                task.reminders = task.reminders.map { var r = $0; r.fired = false; return r }
                task.modifiedAt = Date()
                try await tasks.update(task)
                return .json([
                    "success": .bool(true),
                    "current_streak": .int(task.habitCurrentStreak),
                    "longest_streak": .int(task.habitLongestStreak),
                ])
            }
        ).registered
    }

    private static func addReminder(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "add_reminder",
            description: "Add a reminder to a task. Use trigger=offset for 'X before anchor', trigger=absolute for a specific time (also covers snoozing).",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
                "trigger": .string("offset or absolute", enum: ["offset", "absolute"]),
                "offset": .string("ReminderOffset rawValue (when trigger=offset)", enum: ReminderOffset.allCases.map(\.rawValue)),
                "at": .string("ISO 8601 (when trigger=absolute)"),
            ], required: ["id", "trigger"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else { return .error("Missing required parameter: id") }
                guard let trig = args["trigger"]?.stringValue else { return .error("Missing required parameter: trigger") }
                let all = try await tasks.list()
                guard var task = all.first(where: { $0.id == id }) else { return .error("Task not found: \(id)") }

                let reminder: Reminder
                if trig == "offset" {
                    guard let raw = args["offset"]?.stringValue, let off = ReminderOffset(rawValue: raw) else {
                        return .error("offset trigger requires offset")
                    }
                    reminder = Reminder(trigger: .offset(off))
                } else if trig == "absolute" {
                    guard let atStr = args["at"]?.stringValue, let date = DateFormatters.iso8601.date(from: atStr) else {
                        return .error("absolute trigger requires at (ISO 8601)")
                    }
                    reminder = Reminder(trigger: .absolute(date))
                } else {
                    return .error("Unknown trigger: \(trig)")
                }

                task.reminders.append(reminder)
                task.modifiedAt = Date()
                try await tasks.update(task)
                return .json(["success": .bool(true), "reminder_id": .string(reminder.id.uuidString)])
            }
        ).registered
    }

    private static func listTasksForDay(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_tasks_for_day",
            description: "List tasks anchored to a given calendar day (local timezone). Expands recurring habit occurrences.",
            schema: JSONSchemaObject(properties: [
                "date": .string("Calendar day in YYYY-MM-DD"),
                "kinds": .array("Filter by kinds; defaults to all", items: .string(nil, enum: TaskKind.allCases.map(\.rawValue))),
                "include_completed": .boolean("Include completed tasks (default false)"),
            ], required: ["date"]),
            handler: { args in
                guard let dateStr = args["date"]?.stringValue else { return .error("Missing required parameter: date") }
                guard let day = DateFormatters.dayId.date(from: dateStr) else {
                    return .error("Invalid date format. Use YYYY-MM-DD")
                }
                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: day)
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                    return .error("Failed to compute day range")
                }
                let kinds = resolveKinds(args)
                let includeCompleted = args["include_completed"]?.boolValue ?? false

                var items = try await tasks.list()
                items = items.filter { kinds.contains($0.kind) }
                if !includeCompleted { items = items.filter { $0.status != .completed } }
                items = items.filter { occursOnDay(task: $0, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar) }
                return .json(items.map(taskSummary))
            }
        ).registered
    }

    private static func listUpcoming(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_upcoming",
            description: "List tasks whose anchor falls in [now, now+window). Expands the next recurring habit occurrence per task.",
            schema: JSONSchemaObject(properties: [
                "window": .string("Window like '24h', '7d', '30d'. Defaults to 24h."),
                "kinds": .array("Filter by kinds; defaults to all", items: .string(nil, enum: TaskKind.allCases.map(\.rawValue))),
                "limit": .integer("Max results (default 50)"),
            ]),
            handler: { args in
                let hours = parseWindowHours(args["window"]?.stringValue)
                let limit = args["limit"]?.intValue ?? 50
                let kinds = resolveKinds(args)
                let calendar = Calendar.current
                let now = Date()
                guard let upper = calendar.date(byAdding: .hour, value: hours, to: now) else {
                    return .error("Failed to compute window")
                }
                let range = now..<upper

                var items = try await tasks.list()
                items = items.filter { $0.status != .completed && kinds.contains($0.kind) }
                let occurrences: [(Date, TaskItem)] = items.compactMap { task in
                    guard let occ = firstOccurrence(task: task, in: range, calendar: calendar) else { return nil }
                    return (occ, task)
                }
                let sorted = occurrences.sorted { $0.0 < $1.0 }
                let capped = limit > 0 ? Array(sorted.prefix(limit)) : sorted
                return .json(capped.map { taskSummary($0.1) })
            }
        ).registered
    }
}
