import Foundation
import Combine

protocol CaptureStoreAccess: Sendable {
    func observeCaptures() -> AsyncStream<[CaptureItem]>
    func allCaptures() async -> [CaptureItem]
    func appendCapture(_ item: CaptureItem) async -> Bool
    func linkCaptureToDay(_ captureId: UUID, dayId: String) async -> Bool
    func deleteCaptures(with ids: Set<UUID>) async -> Int
}

private final class CaptureObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

final class LiveCaptureStoreAccess: CaptureStoreAccess, @unchecked Sendable {
    private let logStore: LogStore

    init(logStore: LogStore) {
        self.logStore = logStore
    }

    func observeCaptures() -> AsyncStream<[CaptureItem]> {
        AsyncStream { continuation in
            let box = CaptureObservationBox()
            let setupTask = Task { @MainActor [logStore] in
                continuation.yield(logStore.captures)
                box.cancellable = logStore.$captures
                    .dropFirst()
                    .sink { captures in
                        continuation.yield(captures)
                    }
            }

            continuation.onTermination = { @Sendable _ in
                setupTask.cancel()
                Task { @MainActor in
                    box.cancellable?.cancel()
                    box.cancellable = nil
                }
            }
        }
    }

    func allCaptures() async -> [CaptureItem] {
        await MainActor.run {
            logStore.captures
        }
    }

    func appendCapture(_ item: CaptureItem) async -> Bool {
        await MainActor.run {
            guard !logStore.captures.contains(where: { $0.id == item.id }) else {
                return false
            }
            logStore.appendCapture(item)
            return true
        }
    }

    func linkCaptureToDay(_ captureId: UUID, dayId: String) async -> Bool {
        await MainActor.run {
            guard logStore.captures.contains(where: { $0.id == captureId }) else {
                return false
            }

            logStore.linkCaptureToDay(captureId, dayId: dayId)
            return true
        }
    }

    func deleteCaptures(with ids: Set<UUID>) async -> Int {
        await MainActor.run {
            let previousCount = logStore.captures.count
            logStore.deleteCaptures(with: ids)
            return previousCount - logStore.captures.count
        }
    }
}

struct CaptureStoreRepositoryAdapter: CaptureRepository, @unchecked Sendable {
    private let storeAccess: any CaptureStoreAccess

    init(logStore: LogStore) {
        self.storeAccess = LiveCaptureStoreAccess(logStore: logStore)
    }

    init(storeAccess: any CaptureStoreAccess) {
        self.storeAccess = storeAccess
    }

    func observe() -> AsyncStream<[CaptureItem]> {
        storeAccess.observeCaptures()
    }

    func list() async throws -> [CaptureItem] {
        await storeAccess.allCaptures()
    }

    func append(_ item: CaptureItem) async throws {
        guard !item.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let appended = await storeAccess.appendCapture(item)
        guard appended else {
            throw RepositoryError.invalidInput
        }
    }

    func linkToDay(captureId: UUID, dayId: String) async throws {
        let trimmedDayId = dayId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDayId.isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.linkCaptureToDay(captureId, dayId: trimmedDayId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func delete(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else {
            throw RepositoryError.invalidInput
        }

        let removedCount = await storeAccess.deleteCaptures(with: ids)
        guard removedCount > 0 else {
            throw RepositoryError.notFound
        }
    }
}
