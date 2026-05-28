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
            self?.checkForDueTasks()
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

            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private struct DueSignal {
        let task: TaskItem
        let reminder: Reminder
        let fireDate: Date
    }

    private func checkForDueTasks() {
        guard !hasActiveNotification else { return }

        let now = Date()
        let dueSignals = tasks
            .filter { $0.status == .pending }
            .flatMap { dueSignals(for: $0, now: now) }
            .sorted { $0.fireDate < $1.fireDate }

        for signal in dueSignals {
            if scheduleSignal(signal) {
                return
            }
        }
    }

    private func makeDueSignals(for task: TaskItem, now: Date) -> [DueSignal] {
        let anchor = task.anchorDate
        return task.reminders
            .filter { !$0.fired }
            .map { reminder in
                DueSignal(task: task, reminder: reminder, fireDate: reminder.fireDate(forAnchor: anchor))
            }
            .filter { $0.fireDate <= now }
    }

    private func scheduleSignal(_ signal: DueSignal) -> Bool {
        let requestIdentifier = "reminder-\(signal.task.id)-\(signal.reminder.id.uuidString)"
        let notificationKey = requestIdentifier

        let content = UNMutableNotificationContent()
        content.title = "Geo"
        content.body = signal.task.title
        content.sound = .default
        content.userInfo = [
            "taskId": signal.task.id,
            "reminderId": signal.reminder.id.uuidString,
        ]

        return scheduleNotification(
            requestIdentifier: requestIdentifier,
            notificationKey: notificationKey,
            content: content
        ) { [weak self] in
            self?.markReminderFired(taskId: signal.task.id, reminderId: signal.reminder.id)
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

        try? await tasksRepository.update(task)
    }

    private func markReminderFired(taskId: String, reminderId: UUID) {
        Task { @MainActor in
            await updateTask(id: taskId) { task in
                guard let idx = task.reminders.firstIndex(where: { $0.id == reminderId }) else { return }
                task.reminders[idx].fired = true
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
        let reminderIdString = userInfo["reminderId"] as? String

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)

            if let mainWindow = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }

            navigateToTab(.tasks)

            if let taskIdString,
               let reminderIdString,
               let reminderId = UUID(uuidString: reminderIdString) {
                markReminderFired(taskId: taskIdString, reminderId: reminderId)
            } else {
                clearActiveNotificationState()
            }

            completionHandler()
        }
    }
}
