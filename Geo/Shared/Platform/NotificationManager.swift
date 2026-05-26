import Foundation
import Combine
import AppKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    @Published private(set) var hasActiveNotification = false
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var timer: Timer?
    private var checkInterval: TimeInterval = 60
    private var shownNotifications: Set<String> = []
    private var activeNotificationId: String?
    private var dismissTimer: Timer?
    private var tasksRepository: (any TasksRepository)?
    private var tasksObservationTask: Task<Void, Never>?
    private var tasks: [TaskItem] = []
    private let navigateToTab: (AppTab) -> Void

    init(navigateToTab: @escaping (AppTab) -> Void = { _ in }) {
        self.navigateToTab = navigateToTab
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    deinit {
        timer?.invalidate()
        dismissTimer?.invalidate()
        tasksObservationTask?.cancel()
    }

    func configure(tasksRepository: any TasksRepository) {
        self.tasksRepository = tasksRepository
        startTasksObservationIfNeeded()
    }

    func requestAuthorization() async -> Bool {
        let state = await PermissionRegistry.shared.request("notifications")
        await refreshAuthorizationStatus()
        return state.isGranted
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
    }

    func startMonitoring() {
        startTasksObservationIfNeeded()

        Task {
            await refreshAuthorizationStatus()
            if authorizationStatus == .notDetermined {
                _ = await requestAuthorization()
            }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForDueTasks()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.triggerSmartRemindersOnLaunch()
            self?.checkForDueTasks()
        }
    }

    private func triggerSmartRemindersOnLaunch() {
        let calendar = Calendar.current
        let todayTasks = tasks
            .filter { $0.status == .pending }
            .filter { task in
            task.smartReminder && (calendar.isDateInToday(task.startTime) || task.isOverdue || (task.recurrence.isRepeating && task.startTime < Date()))
        }

        guard !todayTasks.isEmpty else { return }

        for task in todayTasks {
            let notificationKey = "launch-\(task.id)"
            guard !shownNotifications.contains(notificationKey) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Geo - Today's Tasks"
            content.body = task.title
            content.sound = .default
            content.userInfo = ["taskId": task.id, "isLaunchReminder": true]

            let request = UNNotificationRequest(
                identifier: "launch-\(task.id)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { [weak self] error in
                Task { @MainActor in
                    if error == nil {
                        self?.shownNotifications.insert(notificationKey)
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        tasksObservationTask?.cancel()
        tasksObservationTask = nil
    }

    func triggerTestNotification() {
        Task {
            await refreshAuthorizationStatus()

            if authorizationStatus == .denied {
                openNotificationSettings()
                return
            }

            if authorizationStatus != .authorized {
                let granted = await requestAuthorization()
                if !granted {
                    openNotificationSettings()
                    return
                }
            }

            let content = UNMutableNotificationContent()
            content.title = "Geo"
            content.body = "Test notification - tap to dismiss"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "test-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private enum DueSignalKind {
        case snooze(until: Date)
        case oneShot(reminder: ReminderOffset)
        case recurring(reminder: RecurringReminder, fireDate: Date)
    }

    private struct DueSignal {
        let task: TaskItem
        let fireDate: Date
        let kind: DueSignalKind
    }

    private func checkForDueTasks() {
        guard !hasActiveNotification else { return }

        let now = Date()
        let dueSignals = tasks
            .filter { $0.status == .pending }
            .compactMap { dueSignal(for: $0, now: now) }
            .sorted { $0.fireDate < $1.fireDate }

        for signal in dueSignals {
            if scheduleDueSignal(signal) {
                return
            }
        }
    }

    private func dueSignal(for task: TaskItem, now: Date) -> DueSignal? {
        guard task.status == .pending else { return nil }

        if let snoozedUntil = task.snoozedUntil {
            guard snoozedUntil <= now else { return nil }
            return DueSignal(task: task, fireDate: snoozedUntil, kind: .snooze(until: snoozedUntil))
        }

        var candidates: [DueSignal] = []

        if let oneShot = oneShotDueReminder(for: task, now: now) {
            candidates.append(
                DueSignal(
                    task: task,
                    fireDate: oneShot.fireDate,
                    kind: .oneShot(reminder: oneShot.reminder)
                )
            )
        }

        if let recurring = dueRecurringReminder(for: task, now: now) {
            candidates.append(
                DueSignal(
                    task: task,
                    fireDate: recurring.fireDate,
                    kind: .recurring(reminder: recurring.reminder, fireDate: recurring.fireDate)
                )
            )
        }

        return candidates.min { $0.fireDate < $1.fireDate }
    }

    private func oneShotDueReminder(for task: TaskItem, now: Date) -> (reminder: ReminderOffset, fireDate: Date)? {
        let dueReminders = task.reminders
            .filter { !task.firedReminders.contains($0) }
            .map { reminder in
                (reminder: reminder, fireDate: task.startTime.addingTimeInterval(reminder.timeInterval))
            }
            .filter { $0.fireDate <= now }
            .sorted { $0.fireDate < $1.fireDate }
        return dueReminders.first
    }

    private func dueRecurringReminder(for task: TaskItem, now: Date) -> (reminder: RecurringReminder, fireDate: Date)? {
        guard !task.recurringReminders.isEmpty else { return nil }
        var dueCandidates: [(reminder: RecurringReminder, fireDate: Date)] = []

        for reminder in task.recurringReminders {
            guard let nextFire = nextRecurringFireDate(for: reminder, taskStart: task.startTime, now: now) else { continue }
            guard nextFire <= now else { continue }
            dueCandidates.append((reminder: reminder, fireDate: nextFire))
        }

        return dueCandidates.min { $0.fireDate < $1.fireDate }
    }

    private func nextRecurringFireDate(for reminder: RecurringReminder, taskStart: Date, now: Date) -> Date? {
        var candidate: Date
        if let lastFired = reminder.lastFired {
            guard let next = reminder.nextFireDate(after: lastFired) else { return nil }
            candidate = next
        } else {
            guard let initial = initialRecurringFireDate(for: reminder, taskStart: taskStart) else { return nil }
            candidate = initial
        }

        var safety = 0
        while safety < 1000 {
            guard let next = reminder.nextFireDate(after: candidate) else { break }
            guard next <= now else { break }
            candidate = next
            safety += 1
        }

        return candidate
    }

    private func initialRecurringFireDate(for reminder: RecurringReminder, taskStart: Date) -> Date? {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: reminder.timeOfDay)
        return calendar.date(
            bySettingHour: timeComponents.hour ?? 9,
            minute: timeComponents.minute ?? 0,
            second: 0,
            of: taskStart
        )
    }

    private func scheduleDueSignal(_ signal: DueSignal) -> Bool {
        switch signal.kind {
        case .snooze(let until):
            return scheduleSnoozeNotification(for: signal.task, until: until)
        case .oneShot(let reminder):
            return scheduleOneShotNotification(for: signal.task, reminder: reminder)
        case .recurring(let reminder, let fireDate):
            return scheduleRecurringNotification(for: signal.task, reminder: reminder, fireDate: fireDate)
        }
    }

    private func scheduleOneShotNotification(for task: TaskItem, reminder: ReminderOffset) -> Bool {
        let keyComponent = sanitizedKeyComponent(reminder.rawValue)
        let requestIdentifier = "oneshot-\(task.id)-\(keyComponent)"
        let notificationKey = "\(task.id)-\(reminder.rawValue)"

        let content = UNMutableNotificationContent()
        content.title = "Geo"
        content.body = task.title
        content.sound = .default
        content.userInfo = ["taskId": task.id, "reminder": reminder.rawValue]

        return scheduleNotification(
            requestIdentifier: requestIdentifier,
            notificationKey: notificationKey,
            content: content
        ) { [weak self] in
            self?.markNotificationDismissed(taskId: task.id, reminder: reminder)
        }
    }

    private func scheduleRecurringNotification(for task: TaskItem, reminder: RecurringReminder, fireDate: Date) -> Bool {
        let requestIdentifier = "recurring-\(task.id)-\(reminder.id.uuidString)-\(Int(fireDate.timeIntervalSince1970))"
        let notificationKey = requestIdentifier

        let content = UNMutableNotificationContent()
        content.title = "Geo"
        content.body = task.title
        content.sound = .default
        content.userInfo = [
            "taskId": task.id,
            "recurringReminderId": reminder.id.uuidString,
            "recurringReminderFireDate": fireDate.timeIntervalSince1970
        ]

        return scheduleNotification(
            requestIdentifier: requestIdentifier,
            notificationKey: notificationKey,
            content: content
        ) { [weak self] in
            self?.markRecurringReminderDismissed(taskId: task.id, reminderId: reminder.id, firedAt: fireDate)
        }
    }

    private func scheduleSnoozeNotification(for task: TaskItem, until: Date) -> Bool {
        let requestIdentifier = "snooze-\(task.id)-\(Int(until.timeIntervalSince1970))"
        let notificationKey = requestIdentifier

        let content = UNMutableNotificationContent()
        content.title = "Geo"
        content.body = task.title
        content.sound = .default
        content.userInfo = [
            "taskId": task.id,
            "isSnoozeReminder": true,
            "snoozedUntil": until.timeIntervalSince1970
        ]

        return scheduleNotification(
            requestIdentifier: requestIdentifier,
            notificationKey: notificationKey,
            content: content
        ) { [weak self] in
            self?.markSnoozedReminderDismissed(taskId: task.id, firedAt: until)
        }
    }

    private func scheduleNotification(
        requestIdentifier: String,
        notificationKey: String,
        content: UNMutableNotificationContent,
        onTimeout: @escaping () -> Void
    ) -> Bool {
        guard !shownNotifications.contains(notificationKey) else { return false }

        hasActiveNotification = true
        activeNotificationId = requestIdentifier
        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.clearActiveNotificationState()
                    self.checkForDueTasks()
                } else {
                    self.shownNotifications.insert(notificationKey)
                }
            }
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.activeNotificationId == requestIdentifier else { return }
                onTimeout()
            }
        }
        return true
    }

    private func clearActiveNotificationState() {
        hasActiveNotification = false
        activeNotificationId = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func sanitizedKeyComponent(_ value: String) -> String {
        let raw = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func scheduleFollowUpCheck(after delay: TimeInterval = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkForDueTasks()
        }
    }

    private func startTasksObservationIfNeeded() {
        guard tasksObservationTask == nil else { return }
        guard let tasksRepository else { return }

        tasksObservationTask = Task { [weak self] in
            for await observedTasks in tasksRepository.observe() {
                guard let self else { break }
                self.tasks = observedTasks
            }
        }
    }

    private func updateTask(id: String, mutate: (inout TaskItem) -> Void) async {
        guard let tasksRepository else { return }
        guard var task = tasks.first(where: { $0.id == id }) else { return }

        mutate(&task)
        task.modifiedAt = Date()

        do {
            try await tasksRepository.update(task)
        } catch {
        }
    }

    private func markNotificationDismissed(taskId: String, reminder: ReminderOffset) {
        Task { @MainActor in
            await updateTask(id: taskId) { task in
                if !task.firedReminders.contains(reminder) {
                    task.firedReminders.append(reminder)
                }
            }
            clearActiveNotificationState()
            scheduleFollowUpCheck()
        }
    }

    private func markRecurringReminderDismissed(taskId: String, reminderId: UUID, firedAt: Date) {
        Task { @MainActor in
            await updateTask(id: taskId) { task in
                guard let index = task.recurringReminders.firstIndex(where: { $0.id == reminderId }) else { return }
                task.recurringReminders[index].lastFired = firedAt
            }
            clearActiveNotificationState()
            scheduleFollowUpCheck()
        }
    }

    private func markSnoozedReminderDismissed(taskId: String, firedAt: Date) {
        Task { @MainActor in
            await updateTask(id: taskId) { task in
                task.snoozedUntil = nil
                if let dueReminder = oneShotDueReminder(for: task, now: firedAt)?.reminder,
                   !task.firedReminders.contains(dueReminder) {
                    task.firedReminders.append(dueReminder)
                }
            }
            clearActiveNotificationState()
            scheduleFollowUpCheck()
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskIdString = userInfo["taskId"] as? String
        let reminderRaw = userInfo["reminder"] as? String
        let recurringReminderIdString = userInfo["recurringReminderId"] as? String
        let recurringReminderFireDateInterval = userInfo["recurringReminderFireDate"] as? TimeInterval
        let isSnoozeReminder = userInfo["isSnoozeReminder"] as? Bool ?? false
        let snoozedUntilInterval = userInfo["snoozedUntil"] as? TimeInterval

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)

            if let mainWindow = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }

            navigateToTab(.tasks)

            if let taskIdString {
                if isSnoozeReminder {
                    let firedAt = snoozedUntilInterval.map { Date(timeIntervalSince1970: $0) } ?? Date()
                    markSnoozedReminderDismissed(taskId: taskIdString, firedAt: firedAt)
                } else if let reminderRaw,
                   let reminder = ReminderOffset(rawValue: reminderRaw) {
                    markNotificationDismissed(taskId: taskIdString, reminder: reminder)
                } else if let recurringReminderIdString,
                          let reminderId = UUID(uuidString: recurringReminderIdString) {
                    let firedAt = recurringReminderFireDateInterval.map { Date(timeIntervalSince1970: $0) } ?? Date()
                    markRecurringReminderDismissed(taskId: taskIdString, reminderId: reminderId, firedAt: firedAt)
                } else {
                    clearActiveNotificationState()
                }
            } else {
                clearActiveNotificationState()
            }

            completionHandler()
        }
    }
}
