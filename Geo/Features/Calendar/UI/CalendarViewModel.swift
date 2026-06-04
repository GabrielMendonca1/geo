import Foundation

struct PositionedEvent: Identifiable {
    var id: String { "\(event.id)-\(position.hashValue)-\(dayOffset)" }
    let event: CalendarEvent
    let position: EventPillPosition
    let dayOffset: Int
}

struct WeekSpanningEvent: Identifiable {
    var id: String { "\(event.id)-\(startDayIndex)-\(row)" }
    let event: CalendarEvent
    let startDayIndex: Int
    let spanDays: Int
    let row: Int
    let position: EventPillPosition
}

struct RecurrenceCursor: Sequence, IteratorProtocol {
    private var current: Date
    private let task: TaskItem
    private let endBound: Date
    private let calendar: Calendar
    private let rule: RecurrenceRule

    init(task: TaskItem, startFrom: Date, endBound: Date, calendar: Calendar = .current) {
        self.task = task
        self.current = startFrom
        self.endBound = endBound
        self.calendar = calendar
        self.rule = task.recurrence
    }

    mutating func next() -> Date? {
        guard current <= endBound else { return nil }
        if let endDate = rule.endDate, current > endDate { return nil }
        let result = current
        current = rule.nextDate(after: current, calendar: calendar) ?? Date.distantFuture
        return result
    }
}

private struct EventCacheKey: Hashable {
    let monthStart: Date
    let taskVersion: Int
    let blockVersion: Int
    let filterHash: Int
}

struct CalendarEventBundle {
    let singleDay: [Date: [PositionedEvent]]
    let spanning: [Date: [WeekSpanningEvent]]
    static let empty = CalendarEventBundle(singleDay: [:], spanning: [:])
}

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published private(set) var eventBundle: CalendarEventBundle = .empty

    var singleDayEvents: [Date: [PositionedEvent]] { eventBundle.singleDay }
    var spanningEvents: [Date: [WeekSpanningEvent]] { eventBundle.spanning }

    private let holidayService: any HolidayServiceProviding
    private let calendar = Calendar.current

    var filter: CalendarFilter = CalendarFilter() {
        didSet { if filter != oldValue { scheduleRebuild() } }
    }

    private var taskVersion: Int = 0
    private var blockVersion: Int = 0

    private var tasks: [TaskItem] = [] {
        didSet {
            taskVersion += 1
            scheduleRebuild()
        }
    }
    private var blocks: [BlockEntity] = [] {
        didSet {
            blockVersion += 1
            scheduleRebuild()
        }
    }
    private(set) var tagsById: [String: Tag] = [:] {
        didSet { scheduleRebuild() }
    }
    private var month: Date = Date() {
        didSet {
            let oldMonth = calendar.startOfMonth(for: oldValue)
            let newMonth = calendar.startOfMonth(for: month)
            if oldMonth != newMonth {
                scheduleRebuild()
            }
        }
    }

    private var eventCache: [EventCacheKey: [CalendarEvent]] = [:]
    private let maxCachedMonths = 6
    private var lastPublishedKey: EventCacheKey?

    private var observeTasksTask: Task<Void, Never>?
    private var observeBlocksTask: Task<Void, Never>?
    private var observeTagsTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var isBound = false

    init(holidayService: any HolidayServiceProviding) {
        self.holidayService = holidayService
    }

    deinit {
        observeTasksTask?.cancel()
        observeBlocksTask?.cancel()
        observeTagsTask?.cancel()
        rebuildTask?.cancel()
    }

    func bindIfNeeded(
        tasksRepository: any TasksRepository,
        blocksRepository: any BlocksRepository,
        tagsRepository: any TagsRepository
    ) {
        guard !isBound else { return }
        bind(tasksRepository: tasksRepository, blocksRepository: blocksRepository, tagsRepository: tagsRepository)
    }

    func bind(
        tasksRepository: any TasksRepository,
        blocksRepository: any BlocksRepository,
        tagsRepository: any TagsRepository
    ) {
        guard !isBound else { return }
        isBound = true

        observeTasksTask?.cancel()
        observeBlocksTask?.cancel()
        observeTagsTask?.cancel()

        observeTasksTask = Task { [weak self] in
            for await observedTasks in tasksRepository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.tasks = observedTasks
            }
        }

        observeBlocksTask = Task { [weak self] in
            for await observedBlocks in blocksRepository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.blocks = observedBlocks
            }
        }

        observeTagsTask = Task { [weak self] in
            for await observedTags in tagsRepository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.tagsById = Dictionary(observedTags.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            }
        }
    }

    func refresh(for month: Date) {
        self.month = month
    }

    private func currentCacheKey() -> EventCacheKey {
        EventCacheKey(
            monthStart: calendar.startOfMonth(for: month),
            taskVersion: taskVersion,
            blockVersion: blockVersion,
            filterHash: hashFilter(filter)
        )
    }

    private func rebuildEventCache() {
        let key = currentCacheKey()
        if key == lastPublishedKey { return }
        let allEvents = buildAllEvents(month: month)
        let newSingle = buildSingleDayEvents(allEvents)
        let newSpanning = buildSpanningEvents(allEvents, month: month)
        eventBundle = CalendarEventBundle(singleDay: newSingle, spanning: newSpanning)
        lastPublishedKey = key
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.rebuildEventCache()
            }
        }
    }

    func buildAllEvents(month: Date) -> [CalendarEvent] {
        let monthStart = calendar.startOfMonth(for: month)
        let filterHash = hashFilter(filter)

        let cacheKey = EventCacheKey(
            monthStart: monthStart,
            taskVersion: taskVersion,
            blockVersion: blockVersion,
            filterHash: filterHash
        )

        if let cached = eventCache[cacheKey] {
            PerformanceTracker.shared.recordCacheHit()
            return cached
        }
        PerformanceTracker.shared.recordCacheMiss()

        var events: [CalendarEvent] = []

        let currentYear = calendar.component(.year, from: month)
        let yearsToLoad = [currentYear - 1, currentYear, currentYear + 1]

        if !filter.hiddenTypes.contains(.holidays) {
            for year in yearsToLoad {
                let holidays = holidayService.holidays(for: year, countries: [.brazil, .usa])
                for holiday in holidays {
                    events.append(CalendarEvent.from(holiday: holiday))
                }
            }
        }

        let blocksById = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        let visibleRange = visibleRange(for: month)

        if !filter.hiddenTypes.contains(.tasks) {
            for task in tasks {
                if !passesTagFilter(tagId: tagIdForTask(task, blocksById: blocksById)) { continue }
                if task.recurrence.isRepeating {
                    let firstOcc = firstOccurrenceInRange(task: task, range: visibleRange)
                    let cursor = RecurrenceCursor(
                        task: task,
                        startFrom: firstOcc,
                        endBound: visibleRange.upperBound,
                        calendar: calendar
                    )
                    for date in cursor {
                        events.append(CalendarEvent.from(task: task, occurrenceDate: date, blocksById: blocksById, tagsById: tagsById))
                    }
                } else {
                    events.append(CalendarEvent.from(task: task, blocksById: blocksById, tagsById: tagsById))
                }
            }
        }

        if !filter.hiddenTypes.contains(.blocks) {
            for block in blocks {
                if !passesTagFilter(tagId: blockTagKey(block)) { continue }
                events.append(CalendarEvent.from(block: block, tagsById: tagsById))
            }
        }

        eventCache[cacheKey] = events
        evictStaleCache(currentMonth: monthStart)

        return events
    }

    private func evictStaleCache(currentMonth: Date) {
        guard eventCache.count > maxCachedMonths else { return }
        guard let windowStart = calendar.date(byAdding: .month, value: -3, to: currentMonth),
              let windowEnd = calendar.date(byAdding: .month, value: 3, to: currentMonth) else { return }
        eventCache = eventCache.filter { key, _ in
            key.monthStart >= windowStart && key.monthStart <= windowEnd
        }
    }

    private func hashFilter(_ filter: CalendarFilter) -> Int {
        var hasher = Hasher()
        hasher.combine(filter.hiddenTypes)
        hasher.combine(filter.hiddenTagIds)
        hasher.combine(filter.showUntagged)
        return hasher.finalize()
    }

    private func tagIdForTask(_ task: TaskItem, blocksById: [String: BlockEntity]) -> String? {
        guard let blockId = task.linkedBlockId, let block = blocksById[blockId] else { return nil }
        return blockTagKey(block)
    }

    private func blockTagKey(_ block: BlockEntity) -> String? {
        guard let name = block.metadata.tagName else { return nil }
        return TagStore.canonicalName(name)
    }

    private func passesTagFilter(tagId: String?) -> Bool {
        guard filter.isActive else { return true }
        if filter.hiddenTagIds.isEmpty && filter.showUntagged { return true }
        guard let tagId else { return filter.showUntagged }
        return !filter.hiddenTagIds.contains(tagId)
    }

    func buildSingleDayEvents(_ allEvents: [CalendarEvent]) -> [Date: [PositionedEvent]] {
        var result: [Date: [PositionedEvent]] = [:]

        for event in allEvents where !event.isMultiDay {
            let dayStart = calendar.startOfDay(for: event.startDate)
            let positioned = PositionedEvent(event: event, position: .single, dayOffset: 0)
            result[dayStart, default: []].append(positioned)
        }

        for (date, events) in result {
            result[date] = events.sorted { e1, e2 in
                switch (e1.event.type, e2.event.type) {
                case (.holiday, _): return true
                case (_, .holiday): return false
                case (.task, .block): return true
                case (.block, .task): return false
                default: return e1.event.startDate < e2.event.startDate
                }
            }
        }

        return result
    }

    func buildSpanningEvents(_ allEvents: [CalendarEvent], month _: Date) -> [Date: [WeekSpanningEvent]] {
        var segmentsByWeek: [Date: [WeekSpanningEvent]] = [:]

        let multiDayEvents = allEvents.filter { $0.isMultiDay }

        for event in multiDayEvents {
            let segments = splitEventIntoWeekSegments(event)
            for segment in segments {
                segmentsByWeek[segment.weekStart, default: []].append(segment.spanning)
            }
        }

        var result: [Date: [WeekSpanningEvent]] = [:]

        for (weekStart, events) in segmentsByWeek {
            result[weekStart] = assignRowsSweepLine(events)
        }

        return result
    }

    private func assignRowsSweepLine(_ events: [WeekSpanningEvent]) -> [WeekSpanningEvent] {
        let sorted = events.sorted { $0.startDayIndex < $1.startDayIndex }
        var heap = MinHeap()
        var freeRows: [Int] = []
        var nextRow = 0
        var assigned: [WeekSpanningEvent] = []

        for event in sorted {
            while let top = heap.peek(), top.endDayIndex < event.startDayIndex {
                if let entry = heap.removeMin() { freeRows.append(entry.row) }
            }

            let row: Int
            if let free = freeRows.popLast() {
                row = free
            } else {
                row = nextRow
                nextRow += 1
            }

            assigned.append(WeekSpanningEvent(
                event: event.event,
                startDayIndex: event.startDayIndex,
                spanDays: event.spanDays,
                row: row,
                position: event.position
            ))

            heap.insert(HeapEntry(endDayIndex: event.startDayIndex + event.spanDays - 1, row: row))
        }

        return assigned
    }

    func splitEventIntoWeekSegments(_ event: CalendarEvent) -> [(weekStart: Date, spanning: WeekSpanningEvent)] {
        guard let endDate = event.endDate else { return [] }

        let startDay = calendar.startOfDay(for: event.startDate)
        let endDay = calendar.startOfDay(for: endDate)

        var results: [(weekStart: Date, spanning: WeekSpanningEvent)] = []
        var currentDate = startDay

        while currentDate <= endDay {
            let weekday = calendar.component(.weekday, from: currentDate)
            let daysFromWeekStart = (weekday - calendar.firstWeekday + 7) % 7
            guard let weekStart = calendar.date(byAdding: .day, value: -daysFromWeekStart, to: currentDate) else { break }

            let startDayIndex = daysFromWeekStart
            guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { break }
            let eventEndInWeek = min(endDay, weekEnd)
            let daysInWeek = (calendar.dateComponents([.day], from: currentDate, to: eventEndInWeek).day ?? 0) + 1

            let isFirstSegment = currentDate == startDay
            let isLastSegment = eventEndInWeek >= endDay

            let position: EventPillPosition
            if isFirstSegment && isLastSegment {
                position = .single
            } else if isFirstSegment {
                position = .start
            } else if isLastSegment {
                position = .end
            } else {
                position = .middle
            }

            let spanning = WeekSpanningEvent(
                event: event,
                startDayIndex: startDayIndex,
                spanDays: daysInWeek,
                row: 0,
                position: position
            )
            results.append((weekStart: weekStart, spanning: spanning))

            guard let nextWeekStart = calendar.date(byAdding: .day, value: 1, to: eventEndInWeek) else { break }
            currentDate = nextWeekStart
        }

        return results
    }

    private func visibleRange(for month: Date) -> ClosedRange<Date> {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = 1
        let startOfMonth = calendar.date(from: components) ?? month
        let rangeStart = calendar.date(byAdding: .month, value: -1, to: startOfMonth) ?? startOfMonth
        let rangeEnd = calendar.date(byAdding: .month, value: 2, to: startOfMonth) ?? startOfMonth
        return rangeStart...rangeEnd
    }

    private func firstOccurrenceInRange(task: TaskItem, range: ClosedRange<Date>) -> Date {
        let start = task.startTime
        if start >= range.lowerBound { return start }

        switch task.recurrence.type {
        case .never:
            return start
        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: range.lowerBound).day ?? 0
            return calendar.date(byAdding: .day, value: days, to: start) ?? start
        case .weekly:
            let weeks = calendar.dateComponents([.weekOfYear], from: start, to: range.lowerBound).weekOfYear ?? 0
            return calendar.date(byAdding: .weekOfYear, value: weeks, to: start) ?? start
        case .biweekly:
            let weeks = calendar.dateComponents([.weekOfYear], from: start, to: range.lowerBound).weekOfYear ?? 0
            let biweeks = (weeks / 2) * 2
            return calendar.date(byAdding: .weekOfYear, value: biweeks, to: start) ?? start
        case .monthly:
            let months = calendar.dateComponents([.month], from: start, to: range.lowerBound).month ?? 0
            return calendar.date(byAdding: .month, value: months, to: start) ?? start
        case .yearly:
            let years = calendar.dateComponents([.year], from: start, to: range.lowerBound).year ?? 0
            return calendar.date(byAdding: .year, value: years, to: start) ?? start
        case .custom:
            let interval = task.recurrence.customInterval ?? 1
            let freq = task.recurrence.customFrequency ?? .daily
            switch freq {
            case .daily:
                let days = calendar.dateComponents([.day], from: start, to: range.lowerBound).day ?? 0
                let jumps = (days / interval) * interval
                return calendar.date(byAdding: .day, value: jumps, to: start) ?? start
            case .weekly:
                let weeks = calendar.dateComponents([.weekOfYear], from: start, to: range.lowerBound).weekOfYear ?? 0
                let jumps = (weeks / interval) * interval
                return calendar.date(byAdding: .weekOfYear, value: jumps, to: start) ?? start
            case .monthly:
                let months = calendar.dateComponents([.month], from: start, to: range.lowerBound).month ?? 0
                let jumps = (months / interval) * interval
                return calendar.date(byAdding: .month, value: jumps, to: start) ?? start
            case .yearly:
                let years = calendar.dateComponents([.year], from: start, to: range.lowerBound).year ?? 0
                let jumps = (years / interval) * interval
                return calendar.date(byAdding: .year, value: jumps, to: start) ?? start
            }
        case .weekdays:
            let days = calendar.dateComponents([.day], from: start, to: range.lowerBound).day ?? 0
            let weeks = days / 7
            var current = calendar.date(byAdding: .day, value: weeks * 7, to: start) ?? start
            if calendar.isDateInWeekend(current) {
                current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
            }
            if calendar.isDateInWeekend(current) {
                current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
            }
            return current
        }
    }
}

private struct HeapEntry {
    let endDayIndex: Int
    let row: Int
}

private struct MinHeap {
    private var storage: [HeapEntry] = []

    mutating func insert(_ entry: HeapEntry) {
        storage.append(entry)
        siftUp(storage.count - 1)
    }

    func peek() -> HeapEntry? {
        storage.first
    }

    @discardableResult
    mutating func removeMin() -> HeapEntry? {
        guard !storage.isEmpty else { return nil }
        let min = storage[0]
        let last = storage.removeLast()
        if !storage.isEmpty {
            storage[0] = last
            siftDown(0)
        }
        return min
    }

    var isEmpty: Bool { storage.isEmpty }

    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i].endDayIndex < storage[parent].endDayIndex {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        let count = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < count && storage[left].endDayIndex < storage[smallest].endDayIndex {
                smallest = left
            }
            if right < count && storage[right].endDayIndex < storage[smallest].endDayIndex {
                smallest = right
            }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
