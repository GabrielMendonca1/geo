import Foundation

enum FileSelectionCandidateKind: String, Equatable {
    case selection
    case document
}

struct FileSelectionCandidate: Equatable {
    let kind: FileSelectionCandidateKind
    let url: URL
}

struct FileSelectionSource: Equatable {
    let pid: pid_t
    let bundleIdentifier: String
}

enum FileSelectionAvailability: Equatable {
    case selected
    case noSelection
    case unsupported
}

enum FileSelectionFailure: Error, Equatable {
    case noFrontmostApplication
    case permissionDenied
    case noSelection
    case unsupported
    case timeout
    case providerError
    case sourceChanged
    case invalidURL
    case tooManyItems
    case symbolicLink
    case busy
}

struct FileSelectionResolution: Equatable {
    let requestID: UUID
    let source: FileSelectionSource?
    let candidates: [FileSelectionCandidate]
    let selectionAvailability: FileSelectionAvailability?
    let failure: FileSelectionFailure?

    var selectedURLs: [URL] {
        candidates.filter { $0.kind == .selection }.map(\.url)
    }

    var hasDocumentCandidate: Bool {
        candidates.contains { $0.kind == .document }
    }

    func confirmDocumentCandidate() -> URL? {
        candidates.first { $0.kind == .document }?.url
    }

    static func failed(
        requestID: UUID,
        source: FileSelectionSource?,
        failure: FileSelectionFailure
    ) -> FileSelectionResolution {
        FileSelectionResolution(
            requestID: requestID,
            source: source,
            candidates: [],
            selectionAvailability: nil,
            failure: failure
        )
    }
}

struct FileSelectionDeadline {
    let budgetSeconds: Double
    private let expiry: DispatchTime

    init(seconds: Double) {
        let budget = max(0, seconds)
        budgetSeconds = budget
        expiry = DispatchTime.now() + .nanoseconds(Int(budget * 1_000_000_000))
    }

    var remainingSeconds: Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = expiry.uptimeNanoseconds
        guard end > now else { return 0 }
        return Double(end - now) / 1_000_000_000
    }

    var hasExpired: Bool { remainingSeconds <= 0 }
}

struct RawFileSelection {
    let selectedURLs: [URL]
    let documentURL: URL?
    let selectionAvailability: FileSelectionAvailability

    init(
        selectedURLs: [URL],
        documentURL: URL?,
        selectionAvailability: FileSelectionAvailability? = nil
    ) {
        self.selectedURLs = selectedURLs
        self.documentURL = documentURL
        self.selectionAvailability = selectionAvailability ?? (selectedURLs.isEmpty ? .noSelection : .selected)
    }
}

protocol FrontmostApplicationProviding {
    func frontmostApplication() -> FileSelectionSource?
}

protocol FileSelectionProviding {
    func selection(for source: FileSelectionSource) throws -> RawFileSelection
}

enum FileSelectionPermissionState: Equatable {
    case granted
    case denied
    case undetermined
    case unavailable
}

protocol FileSelectionPermissionProviding {
    func preflightPermission() -> Bool
    func permissionState() -> FileSelectionPermissionState
    @discardableResult func requestPermission() -> Bool
}

extension FileSelectionPermissionProviding {
    func permissionState() -> FileSelectionPermissionState {
        preflightPermission() ? .granted : .denied
    }
}
