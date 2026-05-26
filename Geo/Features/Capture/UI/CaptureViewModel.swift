import Foundation

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var filterText = "" {
        didSet {
            scheduleFilterDebounce()
        }
    }
    @Published private(set) var captures: [CaptureItem] = []
    @Published private(set) var debouncedFilterText = ""

    private var filterDebounceTask: Task<Void, Never>?
    private var observeCapturesTask: Task<Void, Never>?
    private var repository: (any CaptureRepository)?
    private var isBound = false

    func bindIfNeeded(repository: any CaptureRepository) {
        guard !isBound else { return }
        bind(repository: repository)
    }

    func bind(repository: any CaptureRepository) {
        self.repository = repository
        isBound = true
        observeCapturesTask?.cancel()
        observeCapturesTask = Task { [weak self] in
            for await observedCaptures in repository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.captures = observedCaptures
            }
        }
    }

    func deleteCapture(id: UUID) async {
        guard let repository else { return }
        do {
            try await repository.delete(ids: [id])
        } catch {
            return
        }
    }

    func deleteCaptures(ids: Set<UUID>) async {
        guard let repository else { return }
        guard !ids.isEmpty else { return }
        do {
            try await repository.delete(ids: ids)
        } catch {
            return
        }
    }

    func linkCaptureToDay(id: UUID, dayId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.linkToDay(captureId: id, dayId: dayId)
            return true
        } catch {
            return false
        }
    }

    var filteredCaptures: [CaptureItem] {
        let sorted = captures.sorted { $0.timestamp > $1.timestamp }
        guard !debouncedFilterText.isEmpty else { return sorted }

        return sorted.filter { capture in
            capture.fileName.localizedCaseInsensitiveContains(debouncedFilterText) ||
            (capture.extractedText?.localizedCaseInsensitiveContains(debouncedFilterText) ?? false)
        }
    }

    private func scheduleFilterDebounce() {
        filterDebounceTask?.cancel()
        let nextValue = filterText
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.debouncedFilterText = nextValue
        }
    }

    deinit {
        filterDebounceTask?.cancel()
        observeCapturesTask?.cancel()
    }
}
