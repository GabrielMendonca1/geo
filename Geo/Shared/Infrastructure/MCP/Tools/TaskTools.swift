import Foundation

enum TaskTools {
    static func register(tasks: any TasksRepository) -> [MCPRegisteredTool] {
        [listTasks(tasks), getTask(tasks), createTask(tasks), updateTask(tasks), deleteTask(tasks), completeTask(tasks), listTasksForDay(tasks), listUpcoming(tasks)]
    }

    private static func taskSummary(_ task: TaskItem) -> [String: AnyCodableValue] {
        var entry: [String: AnyCodableValue] = [
            "id": .string(task.id),
            "title": .string(task.title),
            "status": .string(task.status.rawValue),
            "kind": .string(task.kind.rawValue),
            "priority": .string(task.priority.rawValue),
            "start_time": .string(DateFormatters.iso8601.string(from: task.startTime)),
        ]
        if let end = task.endTime {
            entry["end_time"] = .string(DateFormatters.iso8601.string(from: end))
        }
        if let blockId = task.linkedBlockId {
            entry["linked_block_id"] = .string(blockId)
        }
        return entry
    }

    private static func anchorDate(_ task: TaskItem) -> Date? {
        switch task.schedule {
        case .anytime:
            return nil
        case .dueBy(let date), .at(let date, _), .targeting(let date):
            return date
        case .recurring:
            return task.startTime
        }
    }

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
        if case .anytime = task.schedule { return false }
        if task.recurrence.isRepeating {
            var cursor = task.startTime
            var safety = 0
            while cursor <= dayEnd, safety < 4000 {
                if cursor >= dayStart { return true }
                guard let next = task.recurrence.nextDate(after: cursor, calendar: calendar) else { return false }
                if next <= cursor { return false }
                cursor = next
                safety += 1
            }
            return false
        }
        guard let anchor = anchorDate(task) else { return false }
        return anchor >= dayStart && anchor < dayEnd
    }

    private static func firstOccurrence(task: TaskItem, in range: Range<Date>, calendar: Calendar) -> Date? {
        if task.recurrence.isRepeating {
            var cursor = task.startTime
            var safety = 0
            while cursor < range.upperBound, safety < 4000 {
                if cursor >= range.lowerBound { return cursor }
                guard let next = task.recurrence.nextDate(after: cursor, calendar: calendar) else { return nil }
                if next <= cursor { return nil }
                cursor = next
                safety += 1
            }
            return nil
        }
        guard let anchor = anchorDate(task) else { return nil }
        return (anchor >= range.lowerBound && anchor < range.upperBound) ? anchor : nil
    }

    private static func listTasksForDay(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_tasks_for_day",
            description: "List tasks anchored to a given calendar day (local timezone). Expands recurring occurrences.",
            schema: JSONSchemaObject(properties: [
                "date": .string("Calendar day in YYYY-MM-DD"),
                "kinds": .array("Filter by kinds; defaults to all", items: .string(nil, enum: TaskKind.allCases.map(\.rawValue))),
                "include_completed": .boolean("Include completed tasks (default false)"),
            ], required: ["date"]),
            handler: { args in
                guard let dateStr = args["date"]?.stringValue else {
                    return .error("Missing required parameter: date")
                }
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
                if !includeCompleted {
                    items = items.filter { $0.status != .completed }
                }
                items = items.filter { occursOnDay(task: $0, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar) }
                let result = items.map(taskSummary)
                return .json(result)
            }
        ).registered
    }

    private static func listUpcoming(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_upcoming",
            description: "List tasks whose anchor falls in [now, now+window). Expands the next recurring occurrence per task.",
            schema: JSONSchemaObject(properties: [
                "window": .string("Window like '24h', '7d', '30d', or '48h'. Defaults to 24h."),
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
                let result = capped.map { taskSummary($0.1) }
                return .json(result)
            }
        ).registered
    }

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
                if let status = args["status"]?.stringValue {
                    let taskStatus = TaskStatus(rawValue: status) ?? .pending
                    items = items.filter { $0.status == taskStatus }
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
                let result = items.map { task -> [String: AnyCodableValue] in
                    var entry: [String: AnyCodableValue] = [
                        "id": .string(task.id),
                        "title": .string(task.title),
                        "status": .string(task.status.rawValue),
                        "kind": .string(task.kind.rawValue),
                        "priority": .string(task.priority.rawValue),
                        "start_time": .string(DateFormatters.iso8601.string(from: task.startTime)),
                    ]
                    if let end = task.endTime {
                        entry["end_time"] = .string(DateFormatters.iso8601.string(from: end))
                    }
                    if let blockId = task.linkedBlockId {
                        entry["linked_block_id"] = .string(blockId)
                    }
                    return entry
                }
                return .json(result)
            }
        ).registered
    }

    private static func getTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_task",
            description: "Get a task's full details by ID.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                let allTasks = try await tasks.list()
                guard let task = allTasks.first(where: { $0.id == id }) else {
                    return .error("Task not found: \(id)")
                }
                let formatter = DateFormatters.iso8601
                var result: [String: AnyCodableValue] = [
                    "id": .string(task.id),
                    "title": .string(task.title),
                    "notes": .string(task.notes),
                    "status": .string(task.status.rawValue),
                    "kind": .string(task.kind.rawValue),
                    "priority": .string(task.priority.rawValue),
                    "start_time": .string(formatter.string(from: task.startTime)),
                    "created_at": .string(formatter.string(from: task.createdAt)),
                    "modified_at": .string(formatter.string(from: task.modifiedAt)),
                    "current_streak": .int(task.currentStreak),
                    "longest_streak": .int(task.longestStreak),
                ]
                if let end = task.endTime {
                    result["end_time"] = .string(formatter.string(from: end))
                }
                if let blockId = task.linkedBlockId {
                    result["linked_block_id"] = .string(blockId)
                }
                if !task.tagIds.isEmpty {
                    result["tag_ids"] = .array(task.tagIds.map { .string($0) })
                }
                if let parentId = task.parentId {
                    result["parent_id"] = .string(parentId)
                }
                if let est = task.estimatedMinutes {
                    result["estimated_minutes"] = .int(est)
                }
                if let ctx = task.context {
                    result["context"] = .string(ctx)
                }
                return .json(result)
            }
        ).registered
    }

    private static func createTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "create_task",
            description: "Create a new task with title and start time. Returns the created task.",
            schema: JSONSchemaObject(properties: [
                "title": .string("Task title"),
                "start_time": .string("ISO 8601 UTC start time"),
                "end_time": .string("ISO 8601 UTC end time (optional)"),
                "notes": .string("Task notes"),
                "linked_block_id": .string("Block ID to link"),
                "reminders": .array("One-shot reminders", items: .string("e.g. 'At time', '15 minutes before'", enum: ReminderOffset.allCases.map(\.rawValue))),
                "recurring_reminders": .array("Recurring reminders", items: .object(nil, properties: [
                    "interval": .integer("Interval between fires"),
                    "frequency": .string("Unit", enum: ["Day", "Week", "Month", "Year"]),
                    "time_of_day": .string("ISO 8601 time to fire"),
                ], required: ["interval", "frequency", "time_of_day"])),
                "recurrence": .object("Task recurrence rule", properties: [
                    "type": .string("Recurrence type", enum: ["never", "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]),
                    "selected_weekdays": .array("Weekdays (1=Sun..7=Sat)", items: .integer()),
                ], required: ["type"]),
                "order_index": .integer("Sort order"),
                "kind": .string("Task kind", enum: TaskKind.allCases.map(\.rawValue)),
                "priority": .string("Task priority", enum: TaskPriority.allCases.map(\.rawValue)),
                "tag_ids": .array("Tag IDs", items: .string()),
                "parent_id": .string("Parent task ID"),
                "estimated_minutes": .integer("Estimated duration in minutes"),
                "context": .string("Context label"),
            ], required: ["title", "start_time"]),
            handler: { args in
                guard let title = args["title"]?.stringValue,
                      let startTimeStr = args["start_time"]?.stringValue else {
                    return .error("Missing required parameters: title, start_time")
                }

                let formatter = DateFormatters.iso8601
                guard let startTime = formatter.date(from: startTimeStr) else {
                    return .error("Invalid start_time format. Use ISO 8601 UTC (e.g. 2026-03-18T12:00:00Z)")
                }

                var endTime: Date?
                if let endStr = args["end_time"]?.stringValue {
                    guard let parsed = formatter.date(from: endStr) else {
                        return .error("Invalid end_time format")
                    }
                    endTime = parsed
                }

                var reminders: [ReminderOffset] = [.atTime]
                if let reminderValues = args["reminders"]?.arrayValue {
                    reminders = reminderValues.compactMap { val -> ReminderOffset? in
                        guard let raw = val.stringValue else { return nil }
                        return ReminderOffset(rawValue: raw)
                    }
                }

                var recurringReminders: [RecurringReminder] = []
                if let rrValues = args["recurring_reminders"]?.arrayValue {
                    for rr in rrValues {
                        guard let obj = rr.objectValue,
                              let interval = obj["interval"]?.intValue,
                              let freqStr = obj["frequency"]?.stringValue,
                              let freq = RecurrenceFrequency(rawValue: freqStr),
                              let todStr = obj["time_of_day"]?.stringValue,
                              let tod = formatter.date(from: todStr) else { continue }
                        recurringReminders.append(RecurringReminder(interval: interval, frequency: freq, timeOfDay: tod))
                    }
                }

                var recurrence: RecurrenceRule = .never
                if let recObj = args["recurrence"]?.objectValue,
                   let typeStr = recObj["type"]?.stringValue,
                   let ruleType = RecurrenceRule.RuleType(rawValue: typeStr) {
                    let weekdays = recObj["selected_weekdays"]?.arrayValue?.compactMap(\.intValue)
                    recurrence = RecurrenceRule(type: ruleType, selectedWeekdays: weekdays)
                }

                var kind: TaskKind = .task
                if let kindStr = args["kind"]?.stringValue, let k = TaskKind(rawValue: kindStr) {
                    kind = k
                }
                var priority: TaskPriority = .unset
                if let priStr = args["priority"]?.stringValue, let p = TaskPriority(rawValue: priStr) {
                    priority = p
                }
                let tagIds = args["tag_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []

                let draft = TaskDraft(
                    title: title,
                    notes: args["notes"]?.stringValue ?? "",
                    linkedBlockId: args["linked_block_id"]?.stringValue,
                    startTime: startTime,
                    endTime: endTime,
                    reminders: reminders,
                    recurringReminders: recurringReminders,
                    recurrence: recurrence,
                    kind: kind,
                    priority: priority,
                    tagIds: tagIds,
                    parentId: args["parent_id"]?.stringValue,
                    estimatedMinutes: args["estimated_minutes"]?.intValue,
                    context: args["context"]?.stringValue
                )

                let task = try await tasks.create(draft)
                return .json(["id": task.id, "title": task.title])
            }
        ).registered
    }

    private static func updateTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "update_task",
            description: "Update task fields. Only pass fields you want to change.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
                "title": .string("New title"),
                "notes": .string("New notes"),
                "status": .string("New status", enum: ["pending", "completed"]),
                "start_time": .string("New ISO 8601 start time"),
                "end_time": .string("New ISO 8601 end time"),
                "linked_block_id": .string("Block ID to link"),
                "order_index": .integer("New sort order"),
                "kind": .string("New kind", enum: TaskKind.allCases.map(\.rawValue)),
                "priority": .string("New priority", enum: TaskPriority.allCases.map(\.rawValue)),
                "tag_ids": .array("New tag IDs", items: .string()),
                "parent_id": .string("New parent task ID"),
                "estimated_minutes": .integer("New estimated duration in minutes"),
                "context": .string("New context label"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                let allTasks = try await tasks.list()
                guard var task = allTasks.first(where: { $0.id == id }) else {
                    return .error("Task not found: \(id)")
                }

                let formatter = DateFormatters.iso8601
                if let title = args["title"]?.stringValue { task.title = title }
                if let notes = args["notes"]?.stringValue { task.notes = notes }
                if let status = args["status"]?.stringValue, let s = TaskStatus(rawValue: status) { task.status = s }
                if let st = args["start_time"]?.stringValue, let d = formatter.date(from: st) { task.startTime = d }
                if let et = args["end_time"]?.stringValue, let d = formatter.date(from: et) { task.endTime = d }
                if let blockId = args["linked_block_id"]?.stringValue { task.linkedBlockId = blockId }
                if let idx = args["order_index"]?.intValue { task.orderIndex = idx }
                if let kindStr = args["kind"]?.stringValue, let k = TaskKind(rawValue: kindStr) { task.kind = k }
                if let priStr = args["priority"]?.stringValue, let p = TaskPriority(rawValue: priStr) { task.priority = p }
                if let tagValues = args["tag_ids"]?.arrayValue { task.tagIds = tagValues.compactMap(\.stringValue) }
                if let parentId = args["parent_id"]?.stringValue { task.parentId = parentId }
                if let est = args["estimated_minutes"]?.intValue { task.estimatedMinutes = est }
                if let ctx = args["context"]?.stringValue { task.context = ctx }
                task.modifiedAt = Date()

                try await tasks.update(task)
                return .json(["success": true])
            }
        ).registered
    }

    private static func deleteTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "delete_task",
            description: "Delete a task by ID.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                try await tasks.delete(id: id)
                return .json(["success": true])
            }
        ).registered
    }

    private static func completeTask(_ tasks: any TasksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "complete_task",
            description: "Mark a task as completed.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Task UUID"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                let allTasks = try await tasks.list()
                guard var task = allTasks.first(where: { $0.id == id }) else {
                    return .error("Task not found: \(id)")
                }
                task.status = .completed
                task.modifiedAt = Date()
                try await tasks.update(task)
                return .json(["success": true])
            }
        ).registered
    }
}
