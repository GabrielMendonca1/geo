import Foundation
import Combine

protocol TagStoreAccess: Sendable {
    func observeTags() -> AsyncStream<[Tag]>
    func allTags() async -> [Tag]
    func tag(for id: String) async -> Tag?
    func createTag(name: String, color: TagColor) async -> Result<Tag, TagStoreError>
    func updateTag(_ tag: Tag) async -> Result<Tag, TagStoreError>
    func deleteTag(id: String) async -> Bool
}

private final class TagsObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

final class LiveTagStoreAccess: TagStoreAccess, @unchecked Sendable {
    private let tagStore: TagStore

    init(tagStore: TagStore) {
        self.tagStore = tagStore
    }

    func observeTags() -> AsyncStream<[Tag]> {
        AsyncStream { continuation in
            let box = TagsObservationBox()
            let setupTask = Task { @MainActor [tagStore] in
                continuation.yield(tagStore.tags)
                box.cancellable = tagStore.$tags
                    .dropFirst()
                    .sink { tags in
                        continuation.yield(tags)
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

    func allTags() async -> [Tag] {
        await MainActor.run {
            tagStore.tags
        }
    }

    func tag(for id: String) async -> Tag? {
        await MainActor.run {
            tagStore.tag(for: id)
        }
    }

    func createTag(name: String, color: TagColor) async -> Result<Tag, TagStoreError> {
        await MainActor.run {
            tagStore.createTag(name: name, color: color)
        }
    }

    func updateTag(_ tag: Tag) async -> Result<Tag, TagStoreError> {
        await MainActor.run {
            tagStore.updateTag(id: tag.id, name: tag.name, color: tag.color)
        }
    }

    func deleteTag(id: String) async -> Bool {
        await MainActor.run {
            tagStore.deleteTag(id: id)
        }
    }
}

struct TagStoreRepositoryAdapter: TagsRepository, @unchecked Sendable {
    private let storeAccess: any TagStoreAccess

    init(tagStore: TagStore) {
        self.storeAccess = LiveTagStoreAccess(tagStore: tagStore)
    }

    init(storeAccess: any TagStoreAccess) {
        self.storeAccess = storeAccess
    }

    func observe() -> AsyncStream<[Tag]> {
        storeAccess.observeTags()
    }

    func list() async throws -> [Tag] {
        await storeAccess.allTags()
    }

    func tag(for id: String) async throws -> Tag? {
        await storeAccess.tag(for: id)
    }

    func create(name: String, color: TagColor) async throws -> Tag {
        switch await storeAccess.createTag(name: name, color: color) {
        case .success(let tag):
            return tag
        case .failure(let error):
            throw repositoryError(from: error)
        }
    }

    func update(_ tag: Tag) async throws -> Tag {
        switch await storeAccess.updateTag(tag) {
        case .success(let updated):
            return updated
        case .failure(let error):
            throw repositoryError(from: error)
        }
    }

    func delete(id: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let deleted = await storeAccess.deleteTag(id: id)
        if !deleted {
            throw RepositoryError.notFound
        }
    }

    private func repositoryError(from error: TagStoreError) -> RepositoryError {
        switch error {
        case .notFound:
            return .notFound
        case .emptyName, .duplicateName:
            return .invalidInput
        }
    }
}
