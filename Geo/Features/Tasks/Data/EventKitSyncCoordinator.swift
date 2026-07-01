import EventKit
import Foundation
import GeoCore

@MainActor
final class EventKitSyncCoordinator {
    private let tasksStore: TasksStore
    private let adapter: EventKitAdapter
    private var observer: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?

    init(tasksStore: TasksStore, adapter: EventKitAdapter = .shared) {
        self.tasksStore = tasksStore
        self.adapter = adapter
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: adapter.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    private func scheduleReconcile() {
        guard adapter.isAuthorized else { return }
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            await self?.reconcile()
        }
    }

    private static let reconcileBatchLimit = 200
    private static let reconcileTimeout: TimeInterval = 5

    private func reconcile() async {
        let mirrored = tasksStore.tasksWithMirroredEvents()
        guard !mirrored.isEmpty else { return }

        let deadline = Date().addingTimeInterval(Self.reconcileTimeout)
        for task in mirrored.prefix(Self.reconcileBatchLimit) {
            guard !Task.isCancelled, Date() < deadline else { return }
            guard let id = task.externalEKEventID else { continue }
            if adapter.wasRecentlyWritten(id) { continue }
            guard let event = adapter.event(withIdentifier: id) else {
                tasksStore.clearEventMirror(taskId: task.id)
                continue
            }
            tasksStore.applyInboundEventEdit(
                taskId: task.id,
                title: event.title,
                start: event.startDate,
                end: event.endDate
            )
        }
    }
}
