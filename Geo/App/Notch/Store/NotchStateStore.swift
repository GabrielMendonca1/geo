import Foundation
import SwiftUI

@MainActor
final class NotchStateStore: ObservableObject {
    enum State: Equatable {
        case hidden
        case expanded
    }

    @Published private(set) var state: State
    @Published var isDragActive: Bool = false
    @Published var isPinned: Bool {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
            if isPinned && state != .expanded {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    state = .expanded
                }
            }
        }
    }

    private static let pinnedKey = "notchDockPinned"
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    init() {
        let pinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
        self.isPinned = pinned
        self.state = pinned ? .expanded : .hidden
    }

    func hoverBegan() {
        collapseTask?.cancel()
        collapseTask = nil
        guard state == .hidden else { return }
        expandTask?.cancel()
        expandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                self.state = .expanded
            }
        }
    }

    func hoverEnded() {
        expandTask?.cancel()
        expandTask = nil
        guard state == .expanded, !isPinned else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                self.state = .hidden
            }
        }
    }

    func togglePin() {
        isPinned.toggle()
    }

    func forceExpand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state = .expanded
        }
    }

    func forceCollapse() {
        guard !isPinned else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            state = .hidden
        }
    }
}
